(* Covariance construction and portfolio risk analytics.
   Sigma = D C D: D from VolaTTM vol forecasts, C a Ledoit–Wolf shrunk correlation. *)
open Types

(* Closes on dates common to every series, most recent [lookback + 1] sessions. *)
let aligned_closes (series : series array) ~lookback =
  if Array.length series = 0 then ([||], [||])
  else
    let tables =
      Array.map (fun s -> let h = Hashtbl.create 1024 in Array.iter (fun b -> Hashtbl.replace h b.date b.c) s.bars; h) series
    in
    let dates =
      Array.to_list series.(0).bars
      |> List.filter_map (fun b -> if Array.for_all (fun h -> Hashtbl.mem h b.date) tables then Some b.date else None)
      |> Array.of_list
    in
    let dates = Util.sub_last dates (lookback + 1) in
    (dates, Array.map (fun d -> Array.map (fun h -> Hashtbl.find h d) tables) dates)

let log_returns (closes : float array array) =
  Array.init (max 0 (Array.length closes - 1)) (fun t -> Array.mapi (fun j c -> log (c /. closes.(t).(j))) closes.(t + 1))

(* Ledoit–Wolf (2004) shrinkage of the sample correlation toward the identity. *)
let shrunk_correlation (r : float array array) =
  let t = Array.length r in
  let n = if t = 0 then 0 else Array.length r.(0) in
  if t < 10 then (Linalg.identity n, 1.0)
  else begin
    let colv j = Array.map (fun row -> row.(j)) r in
    let mu = Array.init n (fun j -> Util.mean (colv j)) in
    let sd = Array.init n (fun j -> let s = Util.std (colv j) in if s > 0. then s else 1.) in
    let x = Array.map (fun row -> Array.mapi (fun j v -> (v -. mu.(j)) /. sd.(j)) row) r in
    let tf = float_of_int t in
    let s =
      Array.init n (fun i -> Array.init n (fun j -> Array.fold_left (fun a row -> a +. (row.(i) *. row.(j))) 0. x /. tf))
    in
    let m = Util.sum (Array.init n (fun i -> s.(i).(i))) /. float_of_int n in
    let d2 = ref 0. and b2 = ref 0. in
    for i = 0 to n - 1 do
      for j = 0 to n - 1 do
        let tgt = if i = j then m else 0. in
        d2 := !d2 +. Float.pow (s.(i).(j) -. tgt) 2.
      done
    done;
    Array.iter
      (fun row ->
        for i = 0 to n - 1 do
          for j = 0 to n - 1 do b2 := !b2 +. Float.pow ((row.(i) *. row.(j)) -. s.(i).(j)) 2. done
        done)
      x;
    let b2 = Float.min (!b2 /. (tf *. tf)) !d2 in
    let delta = if !d2 > 0. then b2 /. !d2 else 1. in
    let c = Array.init n (fun i -> Array.init n (fun j -> ((1. -. delta) *. s.(i).(j)) +. if i = j then delta *. m else 0.)) in
    let dg = Array.init n (fun i -> sqrt c.(i).(i)) in
    (Array.init n (fun i -> Array.init n (fun j -> c.(i).(j) /. (dg.(i) *. dg.(j)))), delta)
  end

let covariance (vols : float array) (corr : float array array) =
  Array.mapi (fun i row -> Array.mapi (fun j c -> vols.(i) *. vols.(j) *. c) row) corr

let port_vol sigma w = sqrt (Float.max 0. (Linalg.quad sigma w))

(* marginal and percentage contributions to total risk *)
let contributions sigma w =
  let sv = Linalg.matvec sigma w in
  let pv = port_vol sigma w in
  let mctr = Array.map (fun x -> if pv > 0. then x /. pv else 0.) sv in
  let ctr = Array.mapi (fun i m -> w.(i) *. m) mctr in
  (mctr, Array.map (fun c -> if pv > 0. then c /. pv else 0.) ctr)

let max_drawdown (daily : float array) =
  let nav = ref 1. and peak = ref 1. and mdd = ref 0. in
  Array.iter
    (fun r ->
      nav := !nav *. (1. +. r);
      peak := Float.max !peak !nav;
      mdd := Float.min !mdd ((!nav /. !peak) -. 1.))
    daily;
  !mdd

type report = {
  nav : float;
  invested : float;
  vol_forecast : float;  (* annualised, 22-session VolaTTM term structure *)
  vol_forecast_1d : float;  (* annualised, next session *)
  var95_1d : float;
  cvar95_1d : float;
  var99_1d : float;
  var95_22d : float;
  hist_var95_1d : float;
  hist_cvar95_1d : float;
  beta : float option;
  tracking_error : float option;
  diversification : float;
  effective_n : float;
  pct_ctr : float array;
  sectors : (string * float) list;
  factor_exposure : (string * float) list;
  alerts : string list;
}

let z95 = 1.6448536 and z99 = 2.3263479

(* [w]: weights by universe index (fraction of NAV). [backcast]: daily portfolio
   returns of these weights over history. [bench]: aligned benchmark returns. *)
let analyse ~(cfg : Config.t) ~nav ~syms ~(sectors : string array) ~(scores : Factors.score array)
    ~(fc : vol_forecast array) ~sigma ~sigma_1d ~(w : float array) ~(backcast : float array)
    ~(bench : float array option) =
  let pv = port_vol sigma w and pv1 = port_vol sigma_1d w in
  let s1 = pv1 /. sqrt 252. and s22 = pv *. sqrt (22. /. 252.) in
  let _, pct = contributions sigma w in
  let invested = Util.sum w in
  let losses = Array.map (fun r -> -.r) backcast in
  let hvar = Util.quantile losses 0.95 in
  let tail = Util.finite (Array.map (fun l -> if l >= hvar then l else nan) losses) in
  let beta, te =
    match bench with
    | Some b when Array.length b = Array.length backcast && Array.length b > 20 ->
        let mb = Util.mean b and mp = Util.mean backcast in
        let cov = ref 0. in
        Array.iteri (fun i x -> cov := !cov +. ((x -. mb) *. (backcast.(i) -. mp))) b;
        let cov = !cov /. float_of_int (Array.length b - 1) in
        let active = Array.mapi (fun i x -> x -. b.(i)) backcast in
        (Some (cov /. Util.variance b), Some (Util.std active *. sqrt 252.))
    | _ -> (None, None)
  in
  let wsum_vol = Util.sum (Array.mapi (fun i x -> x *. fc.(i).vol_term) w) in
  let hhi = Array.fold_left (fun a x -> a +. (x *. x)) 0. w in
  let sec_tbl = Hashtbl.create 16 in
  Array.iteri (fun i s -> Hashtbl.replace sec_tbl s (w.(i) +. Option.value (Hashtbl.find_opt sec_tbl s) ~default:0.)) sectors;
  let sec = Hashtbl.fold (fun k v acc -> if v > 1e-6 then (k, v) :: acc else acc) sec_tbl [] |> List.sort (fun (_, a) (_, b) -> compare b a) in
  let expo name get = (name, if invested > 0. then Util.sum (Array.mapi (fun i x -> x *. get scores.(i)) w) /. invested else 0.) in
  let alerts = ref [] in
  let alert fmt = Printf.ksprintf (fun s -> alerts := s :: !alerts) fmt in
  Array.iteri (fun i x -> if x > cfg.max_weight +. 0.02 then alert "%s is %s of NAV (limit %s)" syms.(i) (Util.pct x) (Util.pct cfg.max_weight)) w;
  List.iter (fun (s, x) -> if x > cfg.max_sector +. 0.02 then alert "sector %s is %s of NAV (limit %s)" s (Util.pct x) (Util.pct cfg.max_sector)) sec;
  (match cfg.target_vol with Some tv when pv > tv *. 1.1 -> alert "forecast vol %s exceeds target %s" (Util.pct pv) (Util.pct tv) | _ -> ());
  Array.iteri
    (fun i x ->
      let f = fc.(i) in
      if x > 0.01 && Float.is_finite f.trailing_vol && f.vol_1d > 1.5 *. f.trailing_vol then
        alert "%s: VolaTTM next-session vol %s vs trailing %s — volatility regime shift" syms.(i) (Util.pct f.vol_1d) (Util.pct f.trailing_vol))
    w;
  Array.iteri (fun i p -> if p > 0.25 then alert "%s contributes %s of portfolio risk" syms.(i) (Util.pct p)) pct;
  {
    nav;
    invested;
    vol_forecast = pv;
    vol_forecast_1d = pv1;
    var95_1d = z95 *. s1 *. nav;
    cvar95_1d = Util.norm_pdf z95 /. 0.05 *. s1 *. nav;
    var99_1d = z99 *. s1 *. nav;
    var95_22d = z95 *. s22 *. nav;
    hist_var95_1d = hvar *. nav;
    hist_cvar95_1d = Util.mean tail *. nav;
    beta;
    tracking_error = te;
    diversification = (if pv > 0. then wsum_vol /. pv else nan);
    effective_n = (if hhi > 0. then invested *. invested /. hhi else 0.);
    pct_ctr = pct;
    sectors = sec;
    factor_exposure =
      [ expo "value" (fun s -> s.Factors.value); expo "quality" (fun s -> s.Factors.quality);
        expo "growth" (fun s -> s.Factors.growth); expo "momentum" (fun s -> s.Factors.momentum);
        expo "low-vol" (fun s -> s.Factors.lowvol); expo "composite" (fun s -> s.Factors.composite) ];
    alerts = List.rev !alerts;
  }
