(* Terminal report and CSV outputs. *)
open Types
open Engine

let p = Printf.printf
let rule title = p "\n== %s %s\n" title (String.make (max 0 (76 - String.length title)) '=')
let opt_f f = function Some x -> f x | None -> "n/a"

let print (r : result) =
  let n = Array.length r.syms in
  p "\nFACTOR PORTFOLIO ENGINE  |  as of %s  |  NAV %s  |  cash %s\n" r.as_of (Util.money r.nav) (Util.money r.cash);
  List.iter (fun w -> p "  ! %s\n" w) r.warnings;

  rule "POSITIONS & RETURNS";
  p "%-10s %8s %10s %13s %7s %13s %8s %11s\n" "symbol" "shares" "price" "value" "weight" "unreal P&L" "unreal%" "day P&L";
  let tot_unreal = ref 0. and tot_day = ref 0. in
  for i = 0 to n - 1 do
    if r.shares.(i) <> 0. then begin
      let v = r.shares.(i) *. r.prices.(i) in
      let cost = r.costs.(i) in
      let unreal = if Float.is_finite cost then (r.prices.(i) -. cost) *. r.shares.(i) else nan in
      let day = (r.prices.(i) -. r.prev_close.(i)) *. r.shares.(i) in
      if Float.is_finite unreal then tot_unreal := !tot_unreal +. unreal;
      tot_day := !tot_day +. day;
      p "%-10s %8.0f %10.2f %s %7s %s %8s %s\n" r.syms.(i) r.shares.(i) r.prices.(i) (Util.rpad 13 (Util.money v)) (Util.pct r.w0.(i))
        (Util.rpad 13 (Util.money unreal)) (Util.spct (r.prices.(i) /. cost -. 1.)) (Util.rpad 11 (Util.money day))
    end
  done;
  p "%-10s %8s %10s %s %7s %s %8s %s\n" "total" "" "" (Util.rpad 13 (Util.money (r.nav -. r.cash))) (Util.pct r.risk_now.invested)
    (Util.rpad 13 (Util.money !tot_unreal)) "" (Util.rpad 11 (Util.money !tot_day));
  (match r.perf with
  | Some s ->
      p "\nHoldings backcast (%d sessions, current weights):\n" s.n_days;
      p "  return %s  ann. %s  vol %s  Sharpe %.2f  Sortino %.2f  max DD %s  hit rate %s\n" (Util.spct s.total_return)
        (Util.spct s.ann_return) (Util.pct s.ann_vol) s.sharpe s.sortino (Util.pct s.max_dd) (Util.pct s.hit_rate);
      Option.iter
        (fun (b : Performance.stats) ->
          p "  benchmark: return %s  ann. %s  vol %s  Sharpe %.2f  max DD %s\n" (Util.spct b.total_return)
            (Util.spct b.ann_return) (Util.pct b.ann_vol) b.sharpe (Util.pct b.max_dd))
        r.perf_bench
  | None -> ());
  (match Performance.twr r.cfg.nav_log with
  | Some (twr, d0, d1, k) -> p "  NAV log time-weighted return %s (%s -> %s, %d marks)\n" (Util.spct twr) d0 d1 k
  | None -> p "  NAV log: fewer than two marks yet (%s)\n" r.cfg.nav_log);

  rule "VOLATILITY FORECASTS (annualised, close-to-close)";
  p "%-10s %-10s %8s %8s %8s %9s %9s %7s\n" "symbol" "source" "1-day" "5-day" "22-day" "22d avg" "trailing" "regime";
  Array.iter
    (fun f ->
      let ratio = f.vol_1d /. f.trailing_vol in
      let regime = if ratio > 1.5 then "RISING" else if ratio < 0.67 then "falling" else "" in
      p "%-10s %-10s %8s %8s %8s %9s %9s %7s\n" f.vsym f.source (Util.pct f.vol_1d) (Util.pct f.vol_5d) (Util.pct f.vol_22d)
        (Util.pct f.vol_term) (Util.pct f.trailing_vol) regime)
    r.forecasts;
  if Array.exists (fun f -> String.contains f.source '*') r.forecasts then
    p "  * fed OHLC proxies instead of intraday realised measures; treat as indicative only\n";

  let risk_block (k : Risk.report) =
    p "  forecast vol %s (next session %s)   invested %s   eff. N %.1f   diversification ratio %.2f\n" (Util.pct k.vol_forecast)
      (Util.pct k.vol_forecast_1d) (Util.pct k.invested) k.effective_n k.diversification;
    p "  1d VaR95 %s  CVaR95 %s  VaR99 %s  | 22d VaR95 %s  | hist 1d VaR95 %s  CVaR95 %s\n" (Util.money k.var95_1d)
      (Util.money k.cvar95_1d) (Util.money k.var99_1d) (Util.money k.var95_22d) (Util.money k.hist_var95_1d)
      (Util.money k.hist_cvar95_1d);
    p "  beta %s   tracking error %s\n" (opt_f (Printf.sprintf "%.2f") k.beta) (opt_f Util.pct k.tracking_error);
    p "  sectors: %s\n" (String.concat "  " (List.map (fun (s, w) -> Printf.sprintf "%s %s" s (Util.pct w)) k.sectors));
    p "  factor tilt (wtd z): %s\n" (String.concat "  " (List.map (fun (s, z) -> Printf.sprintf "%s %+.2f" s z) k.factor_exposure))
  in
  rule "RISK — CURRENT PORTFOLIO";
  risk_block r.risk_now;
  let top = List.init n Fun.id |> List.filter (fun i -> r.w0.(i) > 0.) |> List.sort (fun a b -> compare r.risk_now.pct_ctr.(b) r.risk_now.pct_ctr.(a)) in
  p "  risk contributors: %s\n"
    (String.concat "  " (List.filteri (fun k _ -> k < 5) top |> List.map (fun i -> Printf.sprintf "%s %s" r.syms.(i) (Util.pct r.risk_now.pct_ctr.(i)))));
  p "  correlation shrinkage intensity %.2f\n" r.shrinkage;
  if r.risk_now.alerts = [] then p "  no risk alerts\n" else List.iter (fun a -> p "  ALERT: %s\n" a) r.risk_now.alerts;

  rule "FACTOR RANKING (cross-sectional z-scores)";
  p "%-4s %-10s %-12s %7s %7s %7s %7s %7s %9s %7s\n" "rank" "symbol" "sector" "value" "qual" "growth" "mom" "lowvol" "composite" "alpha";
  let order = List.init n Fun.id |> List.sort (fun a b -> compare r.scores.(b).composite r.scores.(a).composite) in
  List.iteri
    (fun k i ->
      let s = r.scores.(i) in
      p "%-4d %-10s %-12s %+7.2f %+7.2f %+7.2f %+7.2f %+7.2f %+9.2f %7s\n" (k + 1) s.ssym
        (if String.length s.sector > 12 then String.sub s.sector 0 12 else s.sector)
        s.value s.quality s.growth s.momentum s.lowvol s.composite (Util.spct r.alpha.(i)))
    order;

  rule "OPTIMISATION";
  let exp_alpha w = Util.sum (Array.mapi (fun i x -> x *. r.alpha.(i)) w) in
  p "  risk aversion %.2f (used %.2f)   target vol %s   max weight %s   max sector %s\n" r.cfg.risk_aversion r.opt.lambda_used
    (opt_f Util.pct r.cfg.target_vol) (Util.pct r.cfg.max_weight) (Util.pct r.cfg.max_sector);
  p "  expected alpha %s -> %s   forecast vol %s -> %s   alpha/vol %.2f -> %.2f\n" (Util.spct (exp_alpha r.w0))
    (Util.spct (exp_alpha r.opt.weights)) (Util.pct r.risk_now.vol_forecast) (Util.pct r.risk_after.vol_forecast)
    (exp_alpha r.w0 /. r.risk_now.vol_forecast) (exp_alpha r.opt.weights /. r.risk_after.vol_forecast);
  p "  one-way turnover %s   est. cost %s   1d VaR95 %s -> %s\n" (Util.pct r.turnover) (Util.money r.est_cost)
    (Util.money r.risk_now.var95_1d) (Util.money r.risk_after.var95_1d);
  if r.risk_after.alerts <> [] then List.iter (fun a -> p "  post-trade ALERT: %s\n" a) r.risk_after.alerts;

  rule "RECOMMENDATIONS";
  p "%-12s %-10s %8s %8s %10s %13s  %s\n" "action" "symbol" "now" "target" "shares" "notional" "rationale";
  List.iter
    (fun t ->
      p "%-12s %-10s %8s %8s %+10.0f %s  %s\n" t.action t.tsym (Util.pct t.w_now) (Util.pct t.w_target) t.shares_delta
        (Util.rpad 13 (Util.money t.notional)) t.reason)
    r.trades;
  p "\nResearch tool output, not investment advice. VolaTTM is a research model (see its model card).\n%!"

let write_csv (r : result) =
  Util.mkdir_p r.cfg.out_dir;
  let file name rows = Util.write_file (Filename.concat r.cfg.out_dir name) (String.concat "\n" rows ^ "\n") in
  let q s = "\"" ^ String.concat "'" (String.split_on_char '"' s) ^ "\"" in
  file "recommendations.csv"
    ("as_of,symbol,action,weight_now,weight_target,shares_delta,price,notional,reason"
    :: List.map
         (fun t -> Printf.sprintf "%s,%s,%s,%.6f,%.6f,%.0f,%.4f,%.2f,%s" r.as_of t.tsym t.action t.w_now t.w_target t.shares_delta t.price t.notional (q t.reason))
         r.trades);
  file "factor_scores.csv"
    (("symbol,sector,value,quality,growth,momentum,lowvol,composite,alpha,"
     ^ String.concat "," (List.map fst r.scores.(0).raw))
    :: Array.to_list
         (Array.mapi
            (fun i (s : Factors.score) ->
              Printf.sprintf "%s,%s,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.6f,%s" s.ssym (q s.sector) s.value s.quality s.growth s.momentum
                s.lowvol s.composite r.alpha.(i)
                (String.concat "," (List.map (fun (_, x) -> Printf.sprintf "%.6g" x) s.raw)))
            r.scores));
  file "vol_forecasts.csv"
    (("symbol,source,scale,vol_1d,vol_5d,vol_22d,vol_term,trailing_vol,"
     ^ String.concat "," (List.init Features_spec.horizon (fun h -> Printf.sprintf "log_rv5_h%d" (h + 1))))
    :: Array.to_list
         (Array.map
            (fun f ->
              Printf.sprintf "%s,%s,%.4f,%.6f,%.6f,%.6f,%.6f,%.6f,%s" f.vsym f.source f.scale f.vol_1d f.vol_5d f.vol_22d f.vol_term
                f.trailing_vol
                (String.concat "," (Array.to_list (Array.map (Printf.sprintf "%.6f") f.log_var_path))))
            r.forecasts));
  p "CSV outputs written to %s/\n%!" r.cfg.out_dir

(* Machine-readable report for the web UI (out/report.json). *)
let write_json (r : result) =
  let open Json in
  let num x = Num x and str x = Str x in
  let arr f a = Arr (Array.to_list (Array.map f a)) in
  let opt f = function Some x -> f x | None -> Null in
  let stats (s : Performance.stats) =
    Obj [ ("total_return", num s.total_return); ("ann_return", num s.ann_return); ("ann_vol", num s.ann_vol);
          ("sharpe", num s.sharpe); ("sortino", num s.sortino); ("max_dd", num s.max_dd); ("hit_rate", num s.hit_rate);
          ("n_days", num (float_of_int s.n_days)) ]
  in
  let risk (k : Risk.report) =
    Obj [ ("invested", num k.invested); ("vol", num k.vol_forecast); ("vol_1d", num k.vol_forecast_1d);
          ("var95_1d", num k.var95_1d); ("cvar95_1d", num k.cvar95_1d); ("var99_1d", num k.var99_1d);
          ("var95_22d", num k.var95_22d); ("hist_var95_1d", num k.hist_var95_1d); ("hist_cvar95_1d", num k.hist_cvar95_1d);
          ("beta", opt num k.beta); ("tracking_error", opt num k.tracking_error);
          ("diversification", num k.diversification); ("effective_n", num k.effective_n);
          ("pct_ctr", arr num k.pct_ctr);
          ("sectors", Arr (List.map (fun (s, w) -> Obj [ ("sector", str s); ("weight", num w) ]) k.sectors));
          ("factor_exposure", Obj (List.map (fun (s, z) -> (s, num z)) k.factor_exposure));
          ("alerts", Arr (List.map str k.alerts)) ]
  in
  let exp_alpha w = Util.sum (Array.mapi (fun i x -> x *. r.alpha.(i)) w) in
  let twr = match Performance.twr r.cfg.nav_log with
    | Some (t, d0, d1, k) -> Obj [ ("twr", num t); ("from", str d0); ("to", str d1); ("marks", num (float_of_int k)) ]
    | None -> Null in
  let j =
    Obj
      [
        ("as_of", str r.as_of);
        ("generated_at", str (let t = Unix.localtime (Unix.time ()) in
           Printf.sprintf "%04d-%02d-%02d %02d:%02d" (t.tm_year + 1900) (t.tm_mon + 1) t.tm_mday t.tm_hour t.tm_min));
        ("currency", str !Util.currency);
        ("nav", num r.nav);
        ("cash", num r.cash);
        ("warnings", Arr (List.map str r.warnings));
        ("assets", arr (fun i ->
             let f = r.forecasts.(i) and s = r.scores.(i) in
             Obj [ ("symbol", str r.syms.(i)); ("sector", str r.sectors.(i)); ("price", num r.prices.(i));
                   ("prev_close", num r.prev_close.(i)); ("shares", num r.shares.(i)); ("cost", num r.costs.(i));
                   ("w_now", num r.w0.(i)); ("w_target", num r.opt.weights.(i)); ("alpha", num r.alpha.(i));
                   ("vol_source", str f.source); ("vol_1d", num f.vol_1d); ("vol_5d", num f.vol_5d); ("vol_22d", num f.vol_22d);
                   ("vol_term", num f.vol_term); ("trailing_vol", num f.trailing_vol);
                   ("value", num s.value); ("quality", num s.quality); ("growth", num s.growth); ("momentum", num s.momentum);
                   ("lowvol", num s.lowvol); ("composite", num s.composite);
                   ("raw", Obj (List.map (fun (k, v) -> (k, num v)) s.raw)) ])
           (Array.init (Array.length r.syms) Fun.id));
        ("perf", opt stats r.perf);
        ("perf_bench", opt stats r.perf_bench);
        ("twr", twr);
        ("risk_now", risk r.risk_now);
        ("risk_after", risk r.risk_after);
        ("optimisation", Obj [ ("risk_aversion", num r.cfg.risk_aversion); ("lambda_used", num r.opt.lambda_used);
                               ("target_vol", opt num r.cfg.target_vol); ("hit_target", Bool r.opt.hit_target);
                               ("alpha_now", num (exp_alpha r.w0)); ("alpha_target", num (exp_alpha r.opt.weights));
                               ("turnover", num r.turnover); ("est_cost", num r.est_cost) ]);
        ("trades", Arr (List.map (fun t ->
             Obj [ ("symbol", str t.tsym); ("action", str t.action); ("w_now", num t.w_now); ("w_target", num t.w_target);
                   ("shares", num t.shares_delta); ("price", num t.price); ("notional", num t.notional); ("reason", str t.reason) ])
           r.trades));
        ("backcast", Obj [ ("dates", arr str r.bc_dates); ("current", arr num r.bc_now); ("target", arr num r.bc_target);
                           ("benchmark", opt (arr num) r.bc_bench) ]);
      ]
  in
  Util.mkdir_p r.cfg.out_dir;
  Util.write_file (Filename.concat r.cfg.out_dir "report.json") (to_string j)
