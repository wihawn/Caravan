(* Cross-sectional factor ranking: value, quality, growth, momentum, low volatility.
   Each raw signal is winsorised (2.5/97.5%), z-scored, optionally sector-demeaned,
   averaged into its category, and the categories are blended into a composite. *)
open Types

type score = {
  ssym : string;
  sector : string;
  value : float;
  quality : float;
  growth : float;
  momentum : float;
  lowvol : float;
  composite : float;
  raw : (string * float) list;
}

let zscore (xs : float array) =
  let fin = Util.finite xs in
  if Array.length fin < 3 then Array.map (fun _ -> 0.) xs
  else
    let lo = Util.quantile fin 0.025 and hi = Util.quantile fin 0.975 in
    let w = Array.map (fun x -> if Float.is_finite x then Util.clip lo hi x else nan) xs in
    let wf = Util.finite w in
    let m = Util.mean wf and s = Util.std wf in
    (* cap at ±3 so one extreme reading (e.g. a base-effect revenue jump) can't dominate *)
    Array.map (fun x -> if Float.is_finite x && s > 0. then Util.clip (-3.) 3. ((x -. m) /. s) else 0.) w

let sector_demean (sectors : string array) (z : float array) =
  let tbl = Hashtbl.create 16 in
  Array.iteri (fun i s -> let a, n = Option.value (Hashtbl.find_opt tbl s) ~default:(0., 0) in Hashtbl.replace tbl s (a +. z.(i), n + 1)) sectors;
  Array.mapi (fun i x -> match Hashtbl.find tbl sectors.(i) with a, n when n >= 2 -> x -. (a /. float_of_int n) | _ -> x) z

(* mean of component z-scores, then re-standardised *)
let category ~neutral sectors (components : float array list) =
  let zs = List.map (fun c -> let z = zscore c in if neutral then sector_demean sectors z else z) components in
  let n = Array.length sectors in
  let avg = Array.init n (fun i -> Util.mean (Array.of_list (List.map (fun z -> z.(i)) zs))) in
  zscore avg

let momentum_signals (bars : bar array) =
  let n = Array.length bars in
  let c k = if n - 1 - k >= 0 then bars.(n - 1 - k).c else nan in
  let mom12_1 = if n > 252 then (c 21 /. c 252) -. 1. else nan in
  let mom6_1 = if n > 126 then (c 21 /. c 126) -. 1. else nan in
  let hi52 =
    if n >= 252 then c 0 /. Array.fold_left (fun a b -> Float.max a b.c) 0. (Util.sub_last bars 252) else nan
  in
  (mom12_1, mom6_1, hi52)

let rank (cfg : Config.t) (series : series array) (fund : (string, fundamentals) Hashtbl.t)
    (vols : vol_forecast array) : score array =
  let n = Array.length series in
  let f i = Hashtbl.find_opt fund series.(i).sym in
  let get g = Array.init n (fun i -> match f i with Some x -> g x | None -> nan) in
  let sectors = Array.init n (fun i -> match f i with Some x -> x.sector | None -> "Unknown") in
  let d = Util.safe_div in
  (* value *)
  let ey = get (fun x -> d x.net_income x.market_cap)
  and bp = get (fun x -> d x.book_equity x.market_cap)
  and fcfy = get (fun x -> d x.free_cash_flow x.market_cap)
  and ebit_ev = get (fun x -> d x.ebit x.enterprise_value) in
  (* quality *)
  let roe = get (fun x -> d x.net_income x.book_equity)
  and gpa = get (fun x -> d x.gross_profit x.total_assets)
  and lev = get (fun x -> -.d x.total_debt x.total_assets)
  and accruals = get (fun x -> -.d (x.net_income -. x.operating_cash_flow) x.total_assets) in
  (* growth *)
  let rev_g = get (fun x -> d x.revenue x.revenue_prev -. 1.) in
  (* momentum *)
  let moms = Array.map (fun s -> momentum_signals s.bars) series in
  let m12 = Array.map (fun (a, _, _) -> a) moms and m6 = Array.map (fun (_, b, _) -> b) moms
  and hi = Array.map (fun (_, _, c) -> c) moms in
  (* low volatility uses the forward-looking VolaTTM term vol *)
  let neg_vol = Array.map (fun v -> -.v.vol_term) vols in
  let neutral = cfg.sector_neutral in
  let value = category ~neutral sectors [ ey; bp; fcfy; ebit_ev ]
  and quality = category ~neutral sectors [ roe; gpa; lev; accruals ]
  and growth = category ~neutral sectors [ rev_g ]
  and momentum = category ~neutral:false sectors [ m12; m6; hi ]
  and lowvol = category ~neutral:false sectors [ neg_vol ] in
  let wsum = cfg.w_value +. cfg.w_quality +. cfg.w_growth +. cfg.w_momentum +. cfg.w_lowvol in
  let blend =
    Array.init n (fun i ->
        ((cfg.w_value *. value.(i)) +. (cfg.w_quality *. quality.(i)) +. (cfg.w_growth *. growth.(i))
        +. (cfg.w_momentum *. momentum.(i)) +. (cfg.w_lowvol *. lowvol.(i)))
        /. wsum)
  in
  let composite = zscore blend in
  Array.init n (fun i ->
      {
        ssym = series.(i).sym;
        sector = sectors.(i);
        value = value.(i);
        quality = quality.(i);
        growth = growth.(i);
        momentum = momentum.(i);
        lowvol = lowvol.(i);
        composite = composite.(i);
        raw =
          [ ("earn_yield", ey.(i)); ("book_price", bp.(i)); ("fcf_yield", fcfy.(i)); ("ebit_ev", ebit_ev.(i));
            ("roe", roe.(i)); ("gross_prof", gpa.(i)); ("debt_assets", -.lev.(i)); ("rev_growth", rev_g.(i));
            ("mom_12_1", m12.(i)); ("mom_6_1", m6.(i)); ("pct_52w_high", hi.(i)) ];
      })

let categories s = [ ("value", s.value); ("quality", s.quality); ("growth", s.growth); ("momentum", s.momentum); ("low-vol", s.lowvol) ]
