let dot a b =
  let s = ref 0. in
  Array.iteri (fun i x -> s := !s +. (x *. b.(i))) a;
  !s

let matvec m v = Array.map (fun row -> dot row v) m
let quad m v = dot v (matvec m v)
let identity n = Array.init n (fun i -> Array.init n (fun j -> if i = j then 1. else 0.))

(* Gaussian elimination with partial pivoting; returns None if singular. *)
let solve a b =
  let n = Array.length b in
  let a = Array.map Array.copy a and b = Array.copy b in
  try
    for k = 0 to n - 1 do
      let p = ref k in
      for i = k + 1 to n - 1 do if Float.abs a.(i).(k) > Float.abs a.(!p).(k) then p := i done;
      if Float.abs a.(!p).(k) < 1e-14 then raise Exit;
      let t = a.(k) in a.(k) <- a.(!p); a.(!p) <- t;
      let t = b.(k) in b.(k) <- b.(!p); b.(!p) <- t;
      for i = k + 1 to n - 1 do
        let f = a.(i).(k) /. a.(k).(k) in
        for j = k to n - 1 do a.(i).(j) <- a.(i).(j) -. (f *. a.(k).(j)) done;
        b.(i) <- b.(i) -. (f *. b.(k))
      done
    done;
    let x = Array.make n 0. in
    for i = n - 1 downto 0 do
      let s = ref b.(i) in
      for j = i + 1 to n - 1 do s := !s -. (a.(i).(j) *. x.(j)) done;
      x.(i) <- !s /. a.(i).(i)
    done;
    Some x
  with Exit -> None
