(* Live tracking. Reads quotes from stdin, one per line:
     SYMBOL,PRICE        (or "SYMBOL PRICE")
   Commands: REPORT (snapshot now), REBALANCE (re-run the full pipeline at live
   prices), QUIT. Pipe any market-data feed into it. *)
open Engine

let run (cfg : Config.t) =
  let quotes = Hashtbl.create 64 in
  let r = ref (Engine.run cfg) in
  Report.print !r;
  Report.write_csv !r;
      Report.write_json !r;
  Array.iteri (fun i s -> Hashtbl.replace quotes s !r.prices.(i)) !r.syms;
  (* session baselines survive a mid-session REBALANCE *)
  let open_nav = !r.nav and open_w = Array.copy !r.w0 and open_px = Array.copy !r.prices in
  let peak = ref open_nav and last_report = ref 0. and ticks = ref 0 in
  let live_nav () =
    let r = !r in
    let px = Array.map (fun s -> Hashtbl.find quotes s) r.syms in
    let nav = r.cash +. Util.sum (Array.mapi (fun i sh -> sh *. px.(i)) r.shares) in
    (px, nav)
  in
  let snapshot () =
    let r = !r in
    let px, nav = live_nav () in
    let w = Array.mapi (fun i sh -> sh *. px.(i) /. nav) r.shares in
    peak := Float.max !peak nav;
    let dd = (nav /. !peak) -. 1. in
    let vol1 = Risk.port_vol r.sigma_1d w in
    let var95 = Risk.z95 *. vol1 /. sqrt 252. *. nav in
    let max_gap a b = Array.fold_left Float.max 0. (Array.mapi (fun i x -> Float.abs (x -. b.(i))) a) in
    let drift = if Array.length open_w = Array.length w then max_gap w open_w else 0. in
    let gap = max_gap w r.opt.weights in
    let t = Unix.localtime (Unix.time ()) in
    Printf.printf "[%02d:%02d:%02d] NAV %s  session %s (%s)  DD %s  live 1d VaR95 %s  drift %s  gap-to-target %s  ticks %d\n"
      t.tm_hour t.tm_min t.tm_sec (Util.money nav) (Util.money (nav -. open_nav)) (Util.spct ((nav /. open_nav) -. 1.)) (Util.pct dd)
      (Util.money var95) (Util.pct drift) (Util.pct gap) !ticks;
    if dd < -.cfg.stop_drawdown then Printf.printf "  ALERT: intraday drawdown %s breaches %s stop\n" (Util.pct dd) (Util.pct cfg.stop_drawdown);
    if drift > 0.02 then Printf.printf "  ALERT: market moves shifted a weight by %s this session — consider REBALANCE\n" (Util.pct drift);
    Array.iteri
      (fun i s ->
        let ret = (px.(i) /. open_px.(i)) -. 1. in
        let sd = r.forecasts.(i).vol_1d /. sqrt 252. in
        if r.shares.(i) <> 0. && Float.abs ret > 3. *. sd then
          Printf.printf "  ALERT: %s moved %s today, %.1f sigma vs VolaTTM next-session forecast\n" s (Util.spct ret) (Float.abs ret /. sd))
      r.syms;
    flush stdout;
    last_report := Unix.gettimeofday ()
  in
  let finish () =
    snapshot ();
    let _, nav = live_nav () in
    Performance.record_nav cfg.nav_log ~date:(Util.today ()) ~nav ~flow:0.;
    Printf.printf "NAV %s recorded to %s\n" (Util.money nav) cfg.nav_log
  in
  Printf.printf "\nLIVE: send 'SYMBOL,PRICE' lines on stdin; commands REPORT | REBALANCE | QUIT\n%!";
  let rec loop () =
    match In_channel.input_line stdin with
    | None -> finish ()
    | Some line -> (
        let line = String.trim line in
        match String.uppercase_ascii line with
        | "" -> loop ()
        | "QUIT" | "EXIT" -> finish ()
        | "REPORT" -> snapshot (); loop ()
        | "REBALANCE" ->
            r := Engine.run ~live_prices:quotes cfg;
            Report.print !r;
            Report.write_csv !r;
      Report.write_json !r;
            loop ()
        | up ->
            (match List.filter (( <> ) "") (String.split_on_char ' ' (String.map (fun c -> if c = ',' || c = '\t' then ' ' else c) up)) with
            | sym :: price :: _ -> (
                match float_of_string_opt price with
                | Some x when x > 0. && Hashtbl.mem quotes sym -> Hashtbl.replace quotes sym x; incr ticks
                | Some _ when not (Hashtbl.mem quotes sym) -> Printf.eprintf "[live] unknown symbol %s\n%!" sym
                | _ -> Printf.eprintf "[live] bad price in %S\n%!" line)
            | _ -> Printf.eprintf "[live] cannot parse %S\n%!" line);
            if Unix.gettimeofday () -. !last_report >= cfg.live_report_secs then snapshot ();
            loop ())
  in
  loop ()
