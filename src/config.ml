(* key = value configuration. Relative paths resolve against the config file's directory. *)

type t = {
  daily_dir : string;
  fundamentals : string;
  holdings : string;
  benchmark : string option;
  nav_log : string;
  out_dir : string;
  cash : float;
  (* VolaTTM sidecar *)
  use_model : bool;
  python : string;
  sidecar : string;
  model_id : string;
  model_revision : string;
  (* ML pipeline inference service *)
  inference_url : string;
  cache_dir : string;
  (* ranking *)
  w_value : float;
  w_quality : float;
  w_growth : float;
  w_momentum : float;
  w_lowvol : float;
  sector_neutral : bool;
  ic : float;
  (* optimisation *)
  risk_aversion : float;
  max_weight : float;
  max_sector : float;
  min_invested : float;
  max_invested : float;
  target_vol : float option;
  tc_bps : float;
  holding_days : int;  (* expected holding period; trading costs are amortised over it *)
  min_trade : float;
  (* risk *)
  corr_lookback : int;
  risk_free : float;
  (* live *)
  live_report_secs : float;
  stop_drawdown : float;
}

let load path =
  let base = Filename.dirname path in
  let kv = Hashtbl.create 32 in
  List.iter
    (fun line ->
      let line = match String.index_opt line '#' with Some i -> String.sub line 0 i | None -> line in
      match String.index_opt line '=' with
      | Some i ->
          let k = String.lowercase_ascii (String.trim (String.sub line 0 i)) in
          let v = String.trim (String.sub line (i + 1) (String.length line - i - 1)) in
          Hashtbl.replace kv k v
      | None -> ())
    (Util.read_lines path);
  let str k d = Option.value (Hashtbl.find_opt kv k) ~default:d in
  let resolve p = if Filename.is_relative p then Filename.concat base p else p in
  let path_ k d = resolve (str k d) in
  let flt k d =
    match Hashtbl.find_opt kv k with
    | None -> d
    | Some s -> (
        match float_of_string_opt s with
        | Some x -> x
        | None -> failwith (Printf.sprintf "config: %s = %S is not a number" k s))
  in
  let bool k d = match Hashtbl.find_opt kv k with Some s -> List.mem (String.lowercase_ascii s) [ "true"; "yes"; "1" ] | None -> d in
  let opt_path k = match Hashtbl.find_opt kv k with Some "" | None -> None | Some p -> Some (resolve p) in
  let python = str "python" "sidecar/.venv/bin/python" in
  Util.currency := str "currency" "$";
  {
    daily_dir = path_ "daily_dir" "data/daily";
    fundamentals = path_ "fundamentals" "data/fundamentals.csv";
    holdings = path_ "holdings" "data/portfolio.csv";
    benchmark = opt_path "benchmark";
    nav_log = path_ "nav_log" "data/nav_log.csv";
    out_dir = path_ "out_dir" "out";
    cash = flt "cash" 0.;
    use_model = bool "use_model" true;
    python = (if String.contains python '/' then resolve python else python);
    sidecar = path_ "sidecar" "sidecar/volattm_server.py";
    model_id = str "model_id" "AurelPx/VolaTTM";
    model_revision = str "model_revision" "d469ad3aa7a35f973a2476709ebdd802258d4be1";
    inference_url = str "inference_url" "http://127.0.0.1:8766";
    cache_dir = path_ "cache_dir" "../cache";
    w_value = flt "w_value" 0.25;
    w_quality = flt "w_quality" 0.25;
    w_growth = flt "w_growth" 0.10;
    w_momentum = flt "w_momentum" 0.30;
    w_lowvol = flt "w_lowvol" 0.10;
    sector_neutral = bool "sector_neutral" true;
    ic = flt "ic" 0.05;
    risk_aversion = flt "risk_aversion" 2.0;
    max_weight = flt "max_weight" 0.15;
    max_sector = flt "max_sector" 0.40;
    min_invested = flt "min_invested" 0.80;
    max_invested = flt "max_invested" 1.0;
    target_vol = (match flt "target_vol" 0. with x when x > 0. -> Some x | _ -> None);
    tc_bps = flt "tc_bps" 10.;
    holding_days = int_of_float (flt "holding_days" 126.);
    min_trade = flt "min_trade" 0.005;
    corr_lookback = int_of_float (flt "corr_lookback" 252.);
    risk_free = flt "risk_free" 0.04;
    live_report_secs = flt "live_report_secs" 30.;
    stop_drawdown = flt "stop_drawdown" 0.03;
  }
