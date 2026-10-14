(* `fp forecasts`: run Kronos (21-day return) and TTM (21-day volatility) through the
   cached inference client and write out/model_forecasts.json for the web UI.

   TTM volatility is reported in raw Garman–Klass (open-to-close range) units, next to
   the trailing 21-day GK volatility in the same units. Calibration to close-to-close
   arrives with the feature pipeline in Milestone 3. *)
open Types
module IC = Inference_client

let gk_logvar (b : bar) = log (Data.gk_variance b.o b.h b.l b.c)

let trailing_gk_vol (bars : bar array) =
  let w = Util.sub_last bars 21 in
  sqrt (252. *. Util.mean (Array.map (fun b -> Data.gk_variance b.o b.h b.l b.c) w))

let run (cfg : Config.t) ~all =
  match IC.connect ~base_url:cfg.inference_url ~cache_dir:cfg.cache_dir () with
  | Error e ->
      prerr_endline e;
      exit 3
  | Ok c ->
      let held = List.map (fun h -> h.hsym) (Data.load_holdings cfg.holdings) in
      let series =
        Data.load_universe cfg.daily_dir
        |> List.filter (fun s -> (all || List.mem s.sym held) && Array.length s.bars >= 64)
      in
      if series = [] then (prerr_endline "no symbols to forecast (no holdings with price history?)"; exit 2);
      let as_of = List.fold_left (fun a s -> max a (Util.sub_last s.bars 1).(0).date) "" series in
      Printf.printf "forecasting %d symbols as of %s (Kronos %s, TTM %s)\n%!" (List.length series) as_of
        (Option.value c.health.kronos_model ~default:"?") (Option.value c.health.ttm_branch ~default:"?");
      let t0 = Unix.gettimeofday () in
      let kr, kerr = IC.kronos c ~as_of (List.map (fun s -> (s.sym, s.bars)) series) in
      Printf.printf "kronos done in %.0fs\n%!" (Unix.gettimeofday () -. t0);
      let ttm_in, short =
        List.partition (fun s -> Array.length s.bars >= IC.Ttm.context) series
      in
      let tt, terr = IC.ttm c ~as_of (List.map (fun s -> (s.sym, Array.map gk_logvar (Util.sub_last s.bars IC.Ttm.context))) ttm_in) in
      let errors =
        kerr @ terr @ List.map (fun s -> (s.sym, Printf.sprintf "TTM needs %d sessions, have %d" IC.Ttm.context (Array.length s.bars))) short
      in
      let num x = if Float.is_finite x then `Float x else `Null in
      let item s =
        let last = (Util.sub_last s.bars 1).(0) in
        let k = IC.Smap.find_opt s.sym kr and t = IC.Smap.find_opt s.sym tt in
        `Assoc
          [ ("symbol", `String s.sym); ("held", `Bool (List.mem s.sym held)); ("last_date", `String last.date);
            ("last_close", num last.c);
            ("kronos_return", match k with Some r -> num r.forecast_return | None -> `Null);
            ("kronos_path", match k with Some r -> `List (List.map num r.pred_close) | None -> `Null);
            ("ttm_vol_gk", match t with Some r -> num r.ann_vol | None -> `Null);
            ("trailing_vol_gk", num (trailing_gk_vol s.bars));
            ("errors", `List (List.filter_map (fun (tk, e) -> if tk = s.sym then Some (`String e) else None) errors)) ]
      in
      let tm = Unix.localtime (Unix.time ()) in
      let j =
        `Assoc
          [ ("as_of", `String as_of);
            ("generated_at", `String (Printf.sprintf "%04d-%02d-%02d %02d:%02d" (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min));
            ("scope", `String (if all then "universe" else "holdings"));
            ("device", `String c.health.device);
            ("kronos_model", match c.health.kronos_model with Some m -> `String m | None -> `Null);
            ("kronos_tag", `String (IC.kronos_tag c IC.Kronos.defaults));
            ("ttm_branch", match c.health.ttm_branch with Some b -> `String b | None -> `Null);
            ("cache", `Assoc [ ("hits", `Int c.cache.hits); ("computed", `Int c.cache.misses); ("stale", `Int c.cache.stale) ]);
            ("items", `List (List.map item series)) ]
      in
      Util.mkdir_p cfg.out_dir;
      Yojson.Safe.to_file (Filename.concat cfg.out_dir "model_forecasts.json") j;
      List.iter (fun (tk, e) -> Printf.printf "  ! %s: %s\n" tk e) errors;
      print_endline (IC.cache_summary c);
      Printf.printf "wrote %s\n" (Filename.concat cfg.out_dir "model_forecasts.json")
