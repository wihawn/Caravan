(* One end-of-day session. The realised measures follow VOLARE's definitions
   (variances of log returns over the session, 5-minute sampling). *)
type bar = {
  date : string;
  o : float;
  h : float;
  l : float;
  c : float;
  volume : float;
  trades : float;
  rv5 : float;  (* realised variance, 5-min returns *)
  rv5_ss : float;  (* subsampled realised variance *)
  bv5 : float;  (* bipower variation *)
  rsn5 : float;  (* negative realised semivariance *)
  rk : float;  (* realised kernel *)
  rq5 : float;  (* realised quarticity *)
}

(* [measured] is false when realised measures were proxied from daily OHLC. *)
type series = { sym : string; bars : bar array; measured : bool }

type fundamentals = {
  fsym : string;
  sector : string;
  market_cap : float;
  net_income : float;
  book_equity : float;
  free_cash_flow : float;
  ebit : float;
  enterprise_value : float;
  revenue : float;
  revenue_prev : float;
  gross_profit : float;
  total_assets : float;
  total_debt : float;
  operating_cash_flow : float;
}

type holding = { hsym : string; shares : float; cost : float (* per share; nan if unknown *) }

(* All vols are annualised close-to-close. *)
type vol_forecast = {
  vsym : string;
  log_var_path : float array;  (* model output: log rv5 for sessions t+1..t+22 *)
  scale : float;  (* close-to-close variance / rv5, accounts for the overnight gap *)
  vol_1d : float;
  vol_5d : float;
  vol_22d : float;
  vol_term : float;  (* average variance over the 22-session path *)
  trailing_vol : float;  (* realised over the last 22 sessions *)
  source : string;
}
