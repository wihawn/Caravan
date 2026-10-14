(* Synthetic data so the engine can be exercised end-to-end. Fictitious tickers;
   stochastic log-vol per asset plus a market factor, jumps, and realised measures
   with estimation noise. Two names get a volatility spike in the last month. *)
open Types

let tickers =
  [| ("NOVA", "Technology"); ("QBIT", "Technology"); ("CLDX", "Technology"); ("SEMI", "Technology");
     ("MEDI", "Health Care"); ("GENX", "Health Care"); ("CARE", "Health Care");
     ("BANC", "Financials"); ("INSR", "Financials"); ("PAYS", "Financials");
     ("OILX", "Energy"); ("SOLR", "Energy"); ("GRID", "Utilities");
     ("SHOP", "Consumer"); ("BRND", "Consumer"); ("FOOD", "Consumer") |]

let sessions = 780

let business_dates n =
  let start = 1693526400. (* 2023-09-01 UTC *) in
  let rec go t acc k =
    if k = n then Array.of_list (List.rev acc)
    else
      let tm = Unix.gmtime t in
      if tm.tm_wday = 0 || tm.tm_wday = 6 then go (t +. 86400.) acc k
      else go (t +. 86400.) (Printf.sprintf "%04d-%02d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday :: acc) (k + 1)
  in
  go start [] 0

let generate dir =
  let st = Random.State.make [| 42 |] in
  let g () =
    let u1 = Random.State.float st 1.0 +. 1e-12 and u2 = Random.State.float st 1.0 in
    sqrt (-2. *. log u1) *. cos (2. *. Float.pi *. u2)
  in
  let u () = Random.State.float st 1.0 in
  let dates = business_dates sessions in
  (* market factor *)
  let mu_m = log ((0.14 *. 0.14) /. 252.) in
  let lvm = Array.make sessions mu_m and rm = Array.make sessions 0. in
  for t = 1 to sessions - 1 do
    lvm.(t) <- mu_m +. (0.97 *. (lvm.(t - 1) -. mu_m)) +. (0.15 *. g ());
    rm.(t) <- 0.0003 +. (sqrt (exp lvm.(t)) *. g ())
  done;
  let daily_dir = Filename.concat dir "daily" in
  Util.mkdir_p daily_dir;
  let fund_rows = ref [] and last_px = Hashtbl.create 16 and px_200 = Hashtbl.create 16 in
  Array.iteri
    (fun k (sym, sector) ->
      let quality = g () and value = g () in
      let beta = 0.6 +. (0.8 *. u ()) and idio = 0.15 +. (0.25 *. u ()) in
      let drift = (0.04 +. (0.04 *. quality) +. (0.03 *. value) +. (0.10 *. g ())) /. 252. in
      let mu_i = log ((idio *. idio) /. 252.) in
      let spike = sym = "SEMI" || sym = "OILX" in
      let lv = ref mu_i and pc = ref (20. +. (180. *. u ())) in
      let bars =
        Array.init sessions (fun t ->
            let bump = if spike && t > sessions - 25 then 1.6 *. float_of_int (t - (sessions - 25)) /. 25. else 0. in
            lv := mu_i +. (0.95 *. (!lv -. mu_i)) +. (0.2 *. g ());
            let vi = exp (!lv +. bump) in
            let v = (beta *. beta *. exp lvm.(t)) +. vi in
            let jump = if u () < 0.015 then 3. *. sqrt v *. g () else 0. in
            let r = drift +. (beta *. rm.(t)) +. (sqrt vi *. g ()) +. jump in
            let r_on = 0.35 *. sqrt v *. g () in
            let r_id = r -. r_on in
            let v_id = (0.85 *. v) +. (jump *. jump) in
            let o = !pc *. exp r_on in
            let c = o *. exp r_id in
            let ext () = exp (0.5 *. sqrt v_id *. Float.abs (g ())) in
            let rv5 = v_id *. exp ((0.3 *. g ()) -. 0.045) in
            let js = if jump <> 0. then Util.clip 0. 0.9 (jump *. jump /. v_id) else 0.03 *. Float.abs (g ()) in
            let volume = Float.round (exp (13.5 +. (0.6 *. (!lv +. bump -. mu_i)) +. (0.25 *. g ()))) in
            pc := c;
            {
              date = dates.(t);
              o;
              h = Float.max o c *. ext ();
              l = Float.min o c /. ext ();
              c;
              volume;
              trades = Float.round (volume /. 150.);
              rv5;
              rv5_ss = rv5 *. exp (0.06 *. g ());
              bv5 = rv5 *. (1. -. js);
              rsn5 = rv5 *. Util.clip 0.05 0.95 (0.5 -. (0.15 *. r_id /. sqrt v_id) +. (0.05 *. g ()));
              rk = rv5 *. exp (0.1 *. g ());
              rq5 = rv5 *. rv5 *. 1.2 *. exp (0.3 *. g ());
            })
      in
      Data.write_series (Filename.concat daily_dir (sym ^ ".csv")) bars;
      Hashtbl.replace last_px sym bars.(sessions - 1).c;
      Hashtbl.replace px_200 sym bars.(sessions - 200).c;
      let shares_out = 1e8 *. (1. +. (19. *. u ())) in
      let mcap = bars.(sessions - 1).c *. shares_out in
      let ni = mcap *. (0.05 +. (0.02 *. value) +. (0.005 *. g ())) in
      let be = mcap *. Float.max 0.05 (0.3 +. (0.15 *. value)) in
      let ta = be *. Float.max 1.2 (2.5 +. (0.5 *. g ())) in
      let debt = ta *. Util.clip 0.02 0.7 (0.3 -. (0.1 *. quality)) in
      let gp = ta *. Float.max 0.02 (0.25 +. (0.08 *. quality)) in
      let rev = gp /. 0.45 in
      fund_rows :=
        Printf.sprintf "%s,%s,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f" sym sector mcap ni be
          (ni *. (0.9 +. (0.2 *. g ()))) (ni *. 1.3) (mcap +. debt -. (0.05 *. mcap)) rev
          (rev /. (1.06 +. (0.05 *. quality) +. (0.04 *. g ()))) gp ta debt (ni *. (1.1 +. (0.1 *. quality)))
        :: !fund_rows;
      ignore k)
    tickers;
  Util.write_file (Filename.concat dir "fundamentals.csv")
    ("symbol,sector,market_cap,net_income,book_equity,free_cash_flow,ebit,enterprise_value,revenue,revenue_prev,gross_profit,total_assets,total_debt,operating_cash_flow\n"
    ^ String.concat "\n" (List.rev !fund_rows) ^ "\n");
  let held = [ ("NOVA", 0.22); ("SEMI", 0.14); ("BANC", 0.12); ("OILX", 0.12); ("MEDI", 0.10); ("SHOP", 0.10); ("GRID", 0.08); ("CLDX", 0.07) ] in
  Util.write_file (Filename.concat dir "portfolio.csv")
    ("symbol,shares,cost_basis\n"
    ^ String.concat ""
        (List.map
           (fun (s, w) -> Printf.sprintf "%s,%.0f,%.2f\n" s (Float.round (w *. 1e6 /. Hashtbl.find last_px s)) (Hashtbl.find px_200 s))
           held));
  let level = ref 4000. in
  Util.write_file (Filename.concat dir "benchmark.csv")
    ("date,close\n"
    ^ String.concat ""
        (Array.to_list
           (Array.mapi (fun t d -> if t > 0 then level := !level *. exp rm.(t); Printf.sprintf "%s,%.2f\n" d !level) dates)));
  Printf.printf "Synthetic data for %d tickers x %d sessions written to %s/\n" (Array.length tickers) sessions dir
