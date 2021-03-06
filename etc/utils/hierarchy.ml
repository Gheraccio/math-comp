#load "unix.cma";;
#load "str.cma";;

module MapS = Map.Make(String)

let usage () =
print_endline
{|Usage : ocaml hierarchy.ml [OPTIONS]

Description:
    hierarchy.ml is a small utility to draw a diagram of and verify the
    hierarchy of mathematical structures.  This utility uses the coercion paths
    and the canonical projections between <module>.type types (typically in the
    MathComp library) to draw the diagram.  Indirect edges which can be
    composed of other edges by transitivity are eliminated automatically for
    each kind of edges.  A diagram appears on the standard output in the DOT
    format which can be converted to several image formats by Graphviz.

Options:
    -h, -help:
        Output a usage message and exit.

    -verify:
        Output a proof script to verify the join canonical projections.  The
        options "-canonicals" and "-coercions" are ignored if "-verify" is
        given.

    -canonicals (off|on|color):
        Configure output of edges of canonical projections.  The default value
        is "on".

    -coercions (off|on|color):
        Configure output of edges of coercions.  The default value is "off".
        The value given by this option must be different from that by
        -canonical soption.

    -R dir coqdir:
        This option is given to coqtop: "recursively map physical dir to
        logical coqdir".

    -lib library:
        Specify a Coq library used to draw a diagram.  This option can appear
        repetitively.  If not specified, all.all will be used.|}
;;

let coqtop =
  match Sys.getenv "COQBIN" with
    | exception Not_found -> "coqtop"
    | coqbin ->
      if coqbin.[String.length coqbin - 1] = '/' then
        coqbin ^ "coqtop"
      else
        coqbin ^ "/coqtop"
;;

let parse_canonicals file =
  let lines = ref [] in
  let ic = open_in file in
  let re = Str.regexp
      "^\\([^ ]+\\)\\.sort <- \\([^ ]+\\)\\.sort ( \\([^ ]+\\)\\.\\([^\\. ]+\\) )$" in
  begin
    try while true do
        let line = input_line ic in
        if Str.string_match re line 0
        then
          let to_module = Str.matched_group 1 line in
          let from_module = Str.matched_group 2 line in
          let proj_module = Str.matched_group 3 line in
          if from_module = proj_module || to_module = proj_module then
            lines := (from_module, to_module,
                      proj_module ^ "." ^ Str.matched_group 4 line) :: !lines
      done with End_of_file -> close_in ic
  end;
  List.rev !lines
;;

let parse_coercions file =
  let lines = ref [] in
  let ic = open_in file in
  let re = Str.regexp
      "^\\[\\([^]]+\\)\\] : \\([^ ]+\\)\\.type >-> \\([^ ]+\\)\\.type$" in
  begin
    try while true do
        let line = input_line ic in
        if Str.string_match re line 0
        then
          lines := (Str.matched_group 3 line, Str.matched_group 2 line,
                    Str.matched_group 1 line) :: !lines
      done with End_of_file -> close_in ic
  end;
  List.rev !lines
;;

let map_of_inheritances (inhs : (string * string * string) list) =
  let rec recur m = function
    | [] -> m
    | (from_module, to_module, inh) :: inhs ->
      recur
        (MapS.update to_module
           (function None -> Some MapS.empty | m' -> m')
           (MapS.update from_module
              (function
                | None -> Some (MapS.singleton to_module inh)
                | Some m' -> Some (MapS.add to_module inh m'))
              m))
        inhs
  in
  recur MapS.empty inhs
;;

(* Computes transitive closure by the Floyd-Warshall algorithm *)
let transitive_closure inhs =
  MapS.fold
    (fun j _ inhs' ->
       let mj =
         match MapS.find_opt j inhs' with None -> MapS.empty | Some mj -> mj
       in
       MapS.map (fun mi ->
         match MapS.find_opt j mi with
           | None -> mi
           | Some i_j ->
             MapS.merge (fun _ i_k j_k ->
               match i_k, j_k with
                 | Some i_k, _ -> Some i_k
                 | None, Some j_k -> Some (i_j ^ "; " ^ j_k)
                 | None, None -> None) mi mj) inhs')
    inhs inhs
;;

let minimalize inhs m =
  let rec recur m k =
    match MapS.find_first_opt (fun k' -> String.compare k k' < 0) m with
      | None -> m
      | Some (k', _) ->
        try recur (MapS.merge
                     (fun _ v v' ->
                        match v, v' with Some _, None -> v | _, _ -> None)
                     m (MapS.find k' inhs)) k'
        with Not_found -> recur m k'
  in
  recur m ""
;;

let print_verifier libs inhs =
  Printf.printf
{|(** Generated by etc/utils/hierarchy.ml *)
From mathcomp Require Import %s.

(* `check_join t1 t2 tjoin` assert that the join of `t1` and `t2` is `tjoin`. *)
Tactic Notation "check_join"
       open_constr(t1) open_constr(t2) open_constr(tjoin) :=
  let rec fillargs t :=
    lazymatch type of t with
      | forall _, _ => let t' := open_constr:(t _) in fillargs t'
      | _ => t
    end
  in
  let t1 := fillargs t1 in
  let t2 := fillargs t2 in
  let tjoin := fillargs tjoin in
  let T1 := open_constr:(_ : t1) in
  let T2 := open_constr:(_ : t2) in
  match tt with
    | _ => unify ((fun x : t1 => x : Type) T1) ((fun x : t2 => x : Type) T2)
    | _ => fail "There is no join of" t1 "and" t2 "but is expected to be" tjoin
  end;
  let Tjoin :=
    lazymatch T1 with
      _ (_ ?Tjoin) => Tjoin | _ ?Tjoin => Tjoin | ?Tjoin => Tjoin
    end
  in
  match tt with
    | _ => is_evar Tjoin
    | _ =>
      let Tjoin := eval simpl in (Tjoin : Type) in
      fail "The join of" t1 "and" t2 "is a concrete type" Tjoin
           "but is expected to be" tjoin
  end;
  let tjoin' := type of Tjoin in
  lazymatch tjoin' with
    | tjoin => idtac
    | _ => fail "The join of" t1 "and" t2 "is" tjoin'
                "but is expected to be" tjoin
  end.

Goal False.
|}
    (String.concat " " libs);
  MapS.iter (fun kl ml ->
      MapS.iter (fun kr mr ->
          let m =
            minimalize inhs
              (MapS.merge
                 (fun _ v v' ->
                    match v, v' with Some _, Some _ -> Some () | _, _ -> None)
                 (MapS.add kl "" ml) (MapS.add kr "" mr))
          in
          match MapS.bindings m with
            | [] -> ()
            | [kj, ()] ->
              Printf.printf "check_join %s.type %s.type %s.type.\n" kl kr kj
            | joins ->
              failwith
                (Printf.sprintf
                   "%s and %s have more than two least common children: %s."
                   kl kr (String.concat ", " (List.map fst joins)))
        ) inhs) inhs;
  Printf.printf "Abort.\n"
;;

let () =
  let opt_verify = ref false in
  let opt_canonicals = ref "on" in
  let opt_coercions = ref "off" in
  let opt_libmaps = ref [] in
  let opt_imports = ref [] in
  let tmp_coercions = Filename.temp_file "" ".out" in
  let tmp_canonicals = Filename.temp_file "" ".out" in
  let rec parse = function
    | [] -> ()
    | "-verify" :: rem -> opt_verify := true; parse rem
    | "-canonicals" :: col :: rem -> opt_canonicals := col; parse rem
    | "-coercions" :: col :: rem -> opt_coercions := col; parse rem
    | "-R" :: path :: log :: rem ->
      opt_libmaps := (path, log) :: !opt_libmaps; parse rem
    | "-lib" :: lib :: rem -> opt_imports := lib :: !opt_imports; parse rem
    | "-h" :: _ | "-help" :: _ -> usage (); exit 0
    | _ -> usage (); exit 1
  in
  parse (List.tl (Array.to_list Sys.argv));
  opt_libmaps := List.rev !opt_libmaps;
  opt_imports :=
    if !opt_imports = [] then ["all.all"] else List.rev !opt_imports;
  (* Interact with coqtop *)
  begin
    let (coqtop_out, coqtop_in, _) as coqtop_ch =
      Unix.open_process_full
        (Printf.sprintf "%S -w none " coqtop ^
         String.concat " "
           (List.map (fun (path, log) -> Printf.sprintf "-R %S %S" path log)
              !opt_libmaps))
        (Unix.environment ())
    in
    Printf.fprintf coqtop_in {|
Set Printing Width 4611686018427387903.
From mathcomp Require Import %s.
Redirect %S Print Canonical Projections.
Redirect %S Print Graph.
|}
      (String.concat " " !opt_imports)
      (List.hd (String.split_on_char '.' tmp_canonicals))
      (List.hd (String.split_on_char '.' tmp_coercions));
    close_out coqtop_in;
    try
      while true do ignore (input_line coqtop_out) done
    with End_of_file ->
      if Unix.close_process_full coqtop_ch <> WEXITED 0 then
        failwith "Failed to invoke coqtop."
  end;
  (* Parsing *)
  let canonicals = parse_canonicals tmp_canonicals in
  let coercions = parse_coercions tmp_coercions in
  (* Output *)
  if !opt_verify then
    print_verifier !opt_imports
      (transitive_closure (map_of_inheritances canonicals))
  else begin
    let print_graph opt inhs =
      if opt <> "off" then
        let attr = if opt = "on" then "" else "color=" ^ opt in
        MapS.iter
          (fun k m ->
             MapS.iter (fun k' _ -> Printf.printf "%S -> %S[%s];\n" k k' attr)
               (minimalize inhs m))
          inhs
    in
    print_endline "digraph structures {";
    print_graph !opt_canonicals
      (transitive_closure (map_of_inheritances canonicals));
    print_graph !opt_coercions
      (transitive_closure (map_of_inheritances coercions));
    print_endline "}"
  end;
  Sys.remove tmp_canonicals;
  Sys.remove tmp_coercions;
;;
