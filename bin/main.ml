open Fp

let usage =
  {|fp — factor ranking + VolaTTM risk + risk-adjusted optimisation

usage:
  fp sample [DIR]                       generate synthetic data into DIR (default: data)
  fp realize INTRADAY.csv OUT.csv       build daily realised measures from 1-minute bars
  fp features DAILY.csv                 print the 12-channel VolaTTM input matrix (debugging)
  fp health [CONFIG]                    check the inference service (make up-bg)
  fp forecasts [CONFIG] [--all]         Kronos + TTM forecasts for holdings (or all) -> out/model_forecasts.json
  fp analyze [CONFIG] [--flow AMOUNT]   full run: returns, risk, rankings, trades; logs NAV
  fp live [CONFIG]                      analyze, then mark-to-market quotes streamed on stdin

CONFIG defaults to ./config.ini|}

let config_of args =
  let path = match List.filter (fun a -> String.length a > 0 && a.[0] <> '-') args with p :: _ -> p | [] -> "config.ini" in
  if not (Sys.file_exists path) then (Printf.eprintf "config not found: %s\n" path; exit 2);
  Config.load path

let rec flow_of = function "--flow" :: x :: _ -> float_of_string x | _ :: rest -> flow_of rest | [] -> 0.

let () =
  match List.tl (Array.to_list Sys.argv) with
  | "sample" :: rest -> Sample.generate (match rest with d :: _ -> d | [] -> "data")
  | [ "realize"; input; output ] ->
      let bars = Realized.of_intraday_csv input in
      Data.write_series output bars;
      Printf.printf "%d sessions of realised measures written to %s\n" (Array.length bars) output
  | [ "features"; csv ] ->
      let s = Data.load_series csv (Filename.remove_extension (Filename.basename csv)) in
      print_endline ("date," ^ String.concat "," (Array.to_list Features_spec.channels));
      let m = Features.matrix s.bars in
      let dates = Util.sub_last s.bars (Array.length m) in
      Array.iteri (fun i row -> print_endline (dates.(i).date ^ "," ^ String.concat "," (Array.to_list (Array.map (Printf.sprintf "%.10g") row)))) m
  | "health" :: rest -> (
      let cfg = config_of rest in
      match Inference_client.connect ~base_url:cfg.inference_url ~cache_dir:cfg.cache_dir () with
      | Error e -> prerr_endline e; exit 3
      | Ok c ->
          Printf.printf "inference service OK at %s (device %s)\n" cfg.inference_url c.health.device;
          List.iter (fun (k, v) -> Printf.printf "  %-8s %s\n" k v) c.health.models)
  | "forecasts" :: rest -> Model_forecasts.run (config_of rest) ~all:(List.mem "--all" rest)
  | "infer-smoke" :: rest -> (
      (* end-to-end check of the OCaml client against the running service *)
      let cfg = config_of rest in
      match Inference_client.connect ~base_url:cfg.inference_url ~cache_dir:cfg.cache_dir () with
      | Error e -> prerr_endline e; exit 3
      | Ok c ->
          let series = List.map (fun s -> Data.load_series (Filename.concat cfg.daily_dir (s ^ ".csv")) s) [ "RELIANCE"; "HDFCBANK"; "TITAGARH" ] in
          let as_of = (Util.sub_last (List.hd series).bars 1).(0).date in
          let t0 = Unix.gettimeofday () in
          let kr, ke = Inference_client.kronos_returns c ~as_of (List.map (fun (s : Types.series) -> (s.sym, s.bars)) series) in
          let gk (b : Types.bar) = log (Data.gk_variance b.o b.h b.l b.c) in
          let tt, te = Inference_client.ttm c ~as_of (List.map (fun (s : Types.series) -> (s.sym, Array.map gk (Util.sub_last s.bars 512))) series) in
          Printf.printf "as_of %s  (%.1fs)\n" as_of (Unix.gettimeofday () -. t0);
          Inference_client.Smap.iter (fun k v -> Printf.printf "  kronos  %-9s %+.2f%%\n" k (100. *. v)) kr;
          Inference_client.Smap.iter (fun k (r : Inference_client.Ttm.result) -> Printf.printf "  ttm     %-9s %.1f%%\n" k (100. *. r.ann_vol)) tt;
          List.iter (fun (k, e) -> Printf.printf "  ERROR   %s: %s\n" k e) (ke @ te);
          print_endline (Inference_client.cache_summary c))
  | "analyze" :: rest ->
      let flow = flow_of rest in
      let args = List.filteri (fun i a -> not (a = "--flow" || (i > 0 && List.nth rest (i - 1) = "--flow"))) rest in
      let cfg = config_of args in
      let r = Engine.run cfg in
      Report.print r;
      Report.write_csv r;
      Report.write_json r;
      Performance.record_nav cfg.nav_log ~date:r.as_of ~nav:r.nav ~flow
  | "live" :: rest -> Live.run (config_of rest)
  | _ -> print_endline usage; exit 1
