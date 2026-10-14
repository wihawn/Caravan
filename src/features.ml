(* Port of volatility_fm.volare_data.make_volare_features: one 12-channel row per session.
   Rows with any non-finite channel (or no prior close) are dropped, as in the reference. *)
open Types

let eps = 1e-16
let lg x = log (Float.max x eps)

let matrix (bars : bar array) : float array array =
  let n = Array.length bars in
  let dlog1p get i = if i = 0 then 0. else Util.clip (-3.) 3. (log1p (get bars.(i)) -. log1p (get bars.(i - 1))) in
  let rows = ref [] in
  for i = n - 1 downto 0 do
    let b = bars.(i) in
    let rv5 = Float.max b.rv5 eps in
    let prev_close = if i = 0 then nan else bars.(i - 1).c in
    let row =
      [|
        lg b.rv5;
        lg b.rv5_ss;
        lg b.rk;
        lg b.bv5;
        Util.clip 0. 5. (Float.max 0. (rv5 -. b.bv5) /. rv5);
        Util.clip 0. 1. (b.rsn5 /. rv5);
        lg b.rq5;
        log (b.c /. b.o);
        Util.clip (-0.5) 0.5 (log (b.o /. prev_close));
        log (b.h /. b.l);
        dlog1p (fun x -> x.volume) i;
        dlog1p (fun x -> x.trades) i;
      |]
    in
    let close_return = log (b.c /. prev_close) in
    if Array.for_all Float.is_finite row && Float.is_finite close_return then rows := row :: !rows
  done;
  Array.of_list !rows

(* Last [context_length] valid sessions, or None if history is too short for the model. *)
let window bars =
  let m = matrix bars in
  if Array.length m < Features_spec.context_length then None else Some (Util.sub_last m Features_spec.context_length)
