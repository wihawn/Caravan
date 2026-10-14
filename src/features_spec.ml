(* Mirrors feature_spec.json shipped with AurelPx/VolaTTM. Channel order is load-bearing. *)
let context_length = 512
let horizon = 22
let frequency_token = 8

let channels =
  [| "log_rv5"; "log_rv5_ss"; "log_rk"; "log_bv5"; "jump_share"; "downside_share"; "log_rq5"; "intraday_return";
     "overnight_return"; "log_range"; "log_volume"; "log_trades" |]
