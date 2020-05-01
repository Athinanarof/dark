open Core_kernel
module Util = Libexecution.Util
module Account = Libbackend.Account
open Libbackend
open Libexecution
module RTT = Types.RuntimeT
open Libcommon
open Types
open RTT.HandlerT
module FluidExpression = Libshared.FluidExpression

let flatmap ~(f : 'a -> 'b list) : 'a list -> 'b list =
  List.fold ~init:[] ~f:(fun acc e -> f e @ acc)


(*
let rec strings_of_expr (expr : RTT.expr) : string list =
  match expr with
  | Partial _ | Blank _ ->
      []
  | Filled (_, nexpr) ->
    ( match nexpr with
    | Value v ->
      ( match Dval.parse_literal v with
      | Some (DStr str) ->
          [Unicode_string.to_string str]
      | _ ->
          [] )
    | _ ->
        [] )
   *)

let strings_of_expr (expr : RTT.expr) : string list =
  let fluidExpr : FluidExpression.t = Fluid.toFluidExpr expr in
  let strings = ref [] in
  let processor fe =
    ( match fe with
    | FluidExpression.EString (_, str) ->
        strings := str :: !strings
    | _ ->
        () ) ;
    fe
  in
  fluidExpr |> FluidExpression.postTraversal ~f:processor |> ignore ;
  !strings


let usage () =
  Format.printf
    "Usage: %s <fnNames...>\n  Where <fnNames> is a space-separated list of functions to look for"
    Sys.argv.(0) ;
  exit 1


let prompt str =
  print_string str ;
  Out_channel.flush Out_channel.stdout ;
  match In_channel.input_line In_channel.stdin with None -> "" | Some s -> s


type mumble =
  { host : string
  ; handler : string
  ; tlid : string
  ; str : string }

(* This is not quite the same as to_yojson *)
let mumble_to_pairs m : (string * Yojson.Safe.t) list =
  [ ("host", `String m.host)
  ; ("handler", `String m.handler)
  ; ("tlid", `String m.tlid)
  ; ("str", `String m.str) ]


let process_canvas (canvas : RTT.expr Canvas.canvas ref) : mumble list =
  let handler_name (handler : RuntimeT.expr handler) =
    let spec = handler.spec in
    String.concat
      ( [spec.module_; spec.name; spec.modifier]
      |> List.map ~f:(function Filled (_, s) -> s | Partial _ | Blank _ -> "")
      )
      ~sep:"-"
  in
  let handlers =
    !(canvas : RuntimeT.expr Canvas.canvas ref).handlers
    |> IDMap.data
    |> List.filter_map ~f:Toplevel.as_handler
  in
  handlers
  |> List.fold ~init:[] ~f:(fun acc handler ->
         acc
         @ ( strings_of_expr handler.ast
           |> List.map ~f:(fun str ->
                  { host = !canvas.host
                  ; handler = handler_name handler
                  ; tlid = Types.string_of_id handler.tlid
                  ; str }) ))


let () =
  (* Filter the haystack by looking for strings starting with
   * containing metadata (as in http://metadata) or 169 (in case they tried with
   * an IP address, not sure if that'd work but it might) *)
  let filter (str : string) : bool =
    (* Confirmed we can get a hit on a known needle *)
    (* str |> String.is_substring ~substring:"https://api.airtable.com" *)
    str |> String.is_substring ~substring:"metadata"
    || str |> String.is_substring ~substring:"169"
  in
  (let hosts = Serialize.current_hosts () in
   hosts
   |> List.map ~f:(fun host ->
          let canvas =
            try
              Some
                ( Canvas.load_all host []
                |> Result.map_error ~f:(String.concat ~sep:", ")
                |> Prelude.Result.ok_or_internal_exception "Canvas load error"
                )
            with
            | Pageable.PageableExn e ->
                Log.erroR
                  "Can't load canvas"
                  ~params:[("host", host); ("exn", Exception.exn_to_string e)] ;
                None
            | Exception.DarkException _ as e ->
                Log.erroR
                  "DarkException"
                  ~params:[("host", host); ("exn", Exception.exn_to_string e)] ;
                None
          in
          canvas
          |> Option.map ~f:process_canvas
          |> Option.value ~default:[]
          |> List.filter ~f:(fun e -> e.str |> filter)
          |> List.iter ~f:(fun hit ->
                 Log.infO "hit" ~jsonparams:(hit |> mumble_to_pairs))))
  |> ignore ;
  ()
