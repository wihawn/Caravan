(* End-to-end pipeline: load -> VolaTTM forecasts -> risk model -> factor ranks ->
   optimisation -> trade recommendations. *)
open Types

type trade = {
  tsym : string;
  action : string;
  w_now : float;
  w_target : float;
  shares_delta : float;
  price : float;
  notional : float;
  reason : string;
}

type result = {
  cfg : Config.t;
  as_of : string;
  syms : string array;
  sectors : string array;
  prices : float array;
  prev_close : float array;
  shares : float array;
  costs : float array;
  cash : float;
  nav : float;
  w0 : float array;
  forecasts : vol_forecast array;
  shrinkage : float;
  sigma : float array array;
  sigma_1d : float array array;
  scores : Factors.score array;
  alpha : float array;
  opt : Optimizer.result;
  risk_now : Risk.report;
  risk_after : Risk.report;
  perf : Performance.stats option;
  perf_bench : Performance.stats option;
  (* daily backcast returns over the risk window, for charting *)
  bc_dates : string array;
  bc_now : float array;
  bc_target : float array;
  bc_bench : float array option;
  trades : trade list;
  turnover : float;
  est_cost : float;
  warnings : string list;
}

let min_history = 60

let run ?(live_prices : (string, float) Hashtbl.t option) (cfg : Config.t) =
  let warnings = ref [] in
  let warn fmt = Printf.ksprintf (fun s -> warnings := s :: !warnings) fmt in
  let all = Data.load_universe cfg.daily_dir in
  let series =
    List.filter
      (fun s ->
        let ok = Array.length s.bars >= min_history in
        if not ok then warn "%s skipped: only %d sessions of history" s.sym (Array.length s.bars);
        ok)
      all
    |> Array.of_list
  in
  if Array.length series < 2 then failwith "need at least two symbols with price history in daily_dir";
  let n = Array.length series in
  let syms = Array.map (fun s -> s.sym) series in
  let idx = Hashtbl.create n in
  Array.iteri (fun i s -> Hashtbl.replace idx s i) syms;
  (match List.filter (fun s -> not s.measured) (Array.to_list series) with
  | [] -> ()
  | l when List.length l = n -> warn "no intraday realised measures for any symbol: VolaTTM fed OHLC proxies (out-of-distribution, marked *)"
  | l -> warn "VolaTTM fed OHLC proxies (out-of-distribution, marked *) for: %s" (String.concat ", " (List.map (fun s -> s.sym) l)));
  let holdings = Data.load_holdings cfg.holdings in
  let shares = Array.make n 0. and costs = Array.make n nan in
  List.iter
    (fun h ->
      match Hashtbl.find_opt idx h.hsym with
      | Some i -> shares.(i) <- shares.(i) +. h.shares; costs.(i) <- h.cost
      | None -> warn "holding %s has no price history in %s — excluded from NAV and risk" h.hsym cfg.daily_dir)
    holdings;
  let last_close = Array.map (fun s -> (Util.sub_last s.bars 1).(0).c) series in
  let prev_close = Array.map (fun s -> let b = Util.sub_last s.bars 2 in b.(0).c) series in
  let prices =
    match live_prices with
    | None -> last_close
    | Some tbl -> Array.mapi (fun i s -> Option.value (Hashtbl.find_opt tbl s) ~default:last_close.(i)) syms
  in
  let fund = Data.load_fundamentals cfg.fundamentals in
  let sectors = Array.map (fun s -> match Hashtbl.find_opt fund s with Some f -> f.sector | None -> "Unknown") syms in

  (* risk model *)
  let forecasts = Array.of_list (Volattm.forecast_all cfg (Array.to_list series)) in
  let dates, closes = Risk.aligned_closes series ~lookback:cfg.corr_lookback in
  if Array.length dates < 30 then failwith "fewer than 30 common dates across the universe";
  let rets = Risk.log_returns closes in
  let corr, shrinkage = Risk.shrunk_correlation rets in
  let sigma = Risk.covariance (Array.map (fun f -> f.vol_term) forecasts) corr in
  let sigma_1d = Risk.covariance (Array.map (fun f -> f.vol_1d) forecasts) corr in

  (* ranking and alpha: Grinold's alpha = IC * vol * score *)
  let scores = Factors.rank cfg series fund forecasts in
  let alpha = Array.mapi (fun i s -> cfg.ic *. forecasts.(i).vol_term *. s.Factors.composite) scores in

  (* current portfolio *)
  let nav = cfg.cash +. Util.sum (Array.mapi (fun i sh -> sh *. prices.(i)) shares) in
  if nav <= 0. then failwith "portfolio NAV is zero: set cash in the config or add holdings";
  let w0 = Array.mapi (fun i sh -> sh *. prices.(i) /. nav) shares in

  (* optimisation. Expected returns = equilibrium prior implied by an equal-weight
     reference portfolio (reverse optimisation, as in Black–Litterman) + factor alpha,
     so a zero-alpha universe optimises back to the reference rather than to cash. *)
  let prior = Array.map (fun x -> cfg.risk_aversion *. x) (Linalg.matvec sigma (Array.make n (1. /. float_of_int n))) in
  let expected = Array.mapi (fun i a -> prior.(i) +. a) alpha in
  let sec_names = Array.to_list sectors |> List.sort_uniq compare |> Array.of_list in
  let sector_of = Array.map (fun s -> let r = ref 0 in Array.iteri (fun k x -> if x = s then r := k) sec_names; !r) sectors in
  let problem =
    {
      Optimizer.alpha;
      sigma;
      w0;
      ub = Array.make n cfg.max_weight;
      sector_of;
      n_sectors = Array.length sec_names;
      sector_cap = cfg.max_sector;
      budget_lo = cfg.min_invested;
      budget_hi = cfg.max_invested;
      lambda = cfg.risk_aversion;
      (* one-way cost amortised over the holding period, in annual alpha units *)
      kappa = cfg.tc_bps /. 1e4 *. 252. /. float_of_int (max 1 cfg.holding_days);
    }
  in
  let opt = Optimizer.solve { problem with alpha = expected } ~target_vol:cfg.target_vol in
  (match cfg.target_vol with
  | Some tv when not opt.hit_target -> warn "could not reach target vol %s within constraints (got %s)" (Util.pct tv) (Util.pct opt.vol)
  | _ -> ());

  (* historical backcasts of current and target weights *)
  let backcast w = Array.map (fun r -> Util.sum (Array.mapi (fun j lr -> w.(j) *. (exp lr -. 1.)) r)) rets in
  let bench =
    Option.bind cfg.benchmark (fun path ->
        if not (Sys.file_exists path) then (warn "benchmark file not found: %s" path; None)
        else
          let tbl = Data.load_benchmark path in
          (* index and stock calendars can differ by a few sessions: carry the last
             index close forward over gaps, but require 95% coverage *)
          let hits = Array.fold_left (fun k d -> if Hashtbl.mem tbl d then k + 1 else k) 0 dates in
          let last = ref nan in
          let level = Array.map (fun d -> (match Hashtbl.find_opt tbl d with Some c -> last := c | None -> ()); !last) dates in
          let b = Array.init (Array.length dates - 1) (fun t -> (level.(t + 1) /. level.(t)) -. 1.) in
          if float_of_int hits >= 0.95 *. float_of_int (Array.length dates) && Array.for_all Float.is_finite b then Some b
          else (warn "benchmark covers only %d of %d risk-window dates; beta/tracking error disabled" hits (Array.length dates); None))
  in
  let analyse w =
    Risk.analyse ~cfg ~nav ~syms ~sectors ~scores ~fc:forecasts ~sigma ~sigma_1d ~w ~backcast:(backcast w) ~bench
  in
  let risk_now = analyse w0 and risk_after = analyse opt.weights in
  let perf = if Util.sum w0 > 0. then Some (Performance.stats ~rf:cfg.risk_free (backcast w0)) else None in
  let perf_bench = Option.map (Performance.stats ~rf:cfg.risk_free) bench in

  (* trades *)
  let reason i =
    let s = scores.(i) and f = forecasts.(i) in
    let cats = List.sort (fun (_, a) (_, b) -> compare (Float.abs b) (Float.abs a)) (Factors.categories s) in
    let top = List.filteri (fun k _ -> k < 2) cats |> List.map (fun (nm, z) -> Printf.sprintf "%s %+.1f" nm z) in
    Printf.sprintf "score %+.2f (%s); vol %s fcst/%s trail [%s]; risk share %s->%s" s.composite (String.concat ", " top)
      (Util.pct f.vol_term) (Util.pct f.trailing_vol) f.source (Util.pct risk_now.pct_ctr.(i)) (Util.pct risk_after.pct_ctr.(i))
  in
  let trades =
    List.filter_map
      (fun i ->
        let wn = w0.(i) and wt = opt.weights.(i) in
        let dw = wt -. wn and px = prices.(i) in
        let action, sh =
          if wn > 0. && wt < cfg.min_trade /. 2. then ("SELL (exit)", -.shares.(i))
          else if Float.abs dw < cfg.min_trade then ("HOLD", 0.)
          else if dw > 0. then ((if wn <= 0. then "BUY (new)" else "BUY (add)"), Float.of_int (truncate (dw *. nav /. px)))
          else ("SELL (trim)", -.Float.of_int (truncate (-.dw *. nav /. px)))
        in
        let action = if sh = 0. && action <> "HOLD" then "HOLD" else action in
        if action = "HOLD" && wn <= 0. then None
        else Some { tsym = syms.(i); action; w_now = wn; w_target = wt; shares_delta = sh; price = px; notional = sh *. px; reason = reason i })
      (List.init n Fun.id)
    |> List.sort (fun a b ->
           let rank t = if String.length t.action >= 4 && String.sub t.action 0 4 = "SELL" then 0 else if t.action = "HOLD" then 2 else 1 in
           compare (rank a, -.Float.abs a.notional) (rank b, -.Float.abs b.notional))
  in
  let traded = List.fold_left (fun a t -> a +. Float.abs t.notional) 0. trades in
  {
    cfg;
    as_of = dates.(Array.length dates - 1);
    syms;
    sectors;
    prices;
    prev_close = (match live_prices with None -> prev_close | Some _ -> last_close);
    shares;
    costs;
    cash = cfg.cash;
    nav;
    w0;
    forecasts;
    shrinkage;
    sigma;
    sigma_1d;
    scores;
    alpha;
    opt;
    risk_now;
    risk_after;
    perf;
    perf_bench;
    bc_dates = Array.sub dates 1 (Array.length dates - 1);
    bc_now = backcast w0;
    bc_target = backcast opt.weights;
    bc_bench = bench;
    trades;
    turnover = traded /. (2. *. nav);
    est_cost = traded *. cfg.tc_bps /. 1e4;
    warnings = List.rev !warnings;
  }
