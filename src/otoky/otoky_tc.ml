open Tokyo_common
open Tokyo_cabinet

module Type =
struct
  include Otoky_type

  let type_desc_hash t =
    Digest.string (Type_desc.to_string t.type_desc)

  let type_desc_hash_key = "__otoky_type_desc_hash__"

  let is_type_desc_hash_key k klen =
    (* argh. maybe we should store the type_desc hash somewhere else. but where? *)
    if klen <> String.length type_desc_hash_key
    then false
    else
      let rec loop i =
        if i = klen then true
        else if String.unsafe_get k i <> String.unsafe_get type_desc_hash_key i then false
        else loop (i + 1) in
      loop 0

  let marshall_key t k func =
    let (k, klen) as mk = t.marshall k in
    if is_type_desc_hash_key k klen
    then raise (Error (Einvalid, func, "marshalled value is type_desc_hash key"))
    else mk

  let compare_cstr t a alen b blen =
    match is_type_desc_hash_key a alen, is_type_desc_hash_key b blen with
      | true, true -> 0
      | true, false -> -1
      | false, true -> 1
      | _ -> t.compare (t.unmarshall (a, alen)) (t.unmarshall (b, blen))

  let unmarshall_tclist t tclist =
    try
      let num = Tclist.num tclist in
      let len = ref 0 in
      let rec loop k =
        if k = num
        then []
        else
          let v = Tclist.val_ tclist k len in
          if is_type_desc_hash_key v !len (* XXX could make this a flag *)
          then loop (k + 1)
          else
            let v = t.unmarshall (v, !len) in
            v :: loop (k + 1) in
      let r = loop 0 in
      Tclist.del tclist;
      r
    with e -> Tclist.del tclist; raise e

  let marshall_tclist t list =
    let anum = List.length list in
    let tclist = Tclist.new_ ~anum () in
    try
      List.iter
        (fun v ->
           let (s, len) = t.marshall v in
           Tclist.push tclist s len)
        list;
      tclist
    with e -> Tclist.del tclist; raise e
end

module BDB =
struct
  module BDB_raw = BDB.Fun (Cstr_cstr) (Tclist_tclist)

  type ('k, 'v) t = {
    bdb : BDB.t;
    ktype : 'k Type.t;
    vtype : 'v Type.t;
  }

  let open_ ?omode ktype vtype fn =
    let bdb = BDB.new_ () in
    BDB.setcmpfunc bdb (BDB.Cmp_custom_cstr (Type.compare_cstr ktype));
    BDB.open_ bdb ?omode fn;
    let hash = Type.type_desc_hash ktype ^ Type.type_desc_hash vtype in
    begin try
      if hash <> BDB.get bdb Type.type_desc_hash_key
      then begin
        BDB.close bdb;
        raise (Error (Einvalid, "open_", "bad type_desc hash"))
      end
    with Error (Enorec, _, _) ->
      (* XXX maybe should check that this is a fresh db? *)
      BDB.put bdb Type.type_desc_hash_key hash;
    end;
    {
      bdb = bdb;
      ktype = ktype;
      vtype = vtype;
    }

  let close t = BDB.close t.bdb
  let copy t fn = BDB.copy t.bdb fn
  let fsiz t = BDB.fsiz t.bdb

  let get t k =
    let cstr = BDB_raw.get t.bdb (Type.marshall_key t.ktype k "get") in
    try
      let v = t.vtype.Type.unmarshall cstr in
      Cstr.del cstr;
      v
    with e -> Cstr.del cstr; raise e

  let getlist t k =
    Type.unmarshall_tclist t.vtype
      (BDB_raw.getlist t.bdb (Type.marshall_key t.ktype k "getlist"))

  let optimize t ?lmemb ?nmemb ?bnum ?apow ?fpow ?opts () =
    BDB.optimize t.bdb ?lmemb ?nmemb ?bnum ?apow ?fpow ?opts ()

  let out t k = BDB_raw.out t.bdb (Type.marshall_key t.ktype k "out")
  let outlist t k = BDB_raw.outlist t.bdb (Type.marshall_key t.ktype k "outlist")
  let path t = BDB.path t.bdb

  let put t k v = BDB_raw.put t.bdb (Type.marshall_key t.ktype k "put") (t.vtype.Type.marshall v)
  let putdup t k v = BDB_raw.putdup t.bdb (Type.marshall_key t.ktype k "putdup") (t.vtype.Type.marshall v)
  let putkeep t k v = BDB_raw.putkeep t.bdb (Type.marshall_key t.ktype k "putkeep") (t.vtype.Type.marshall v)
  let putlist t k vs =
    let tclist = Type.marshall_tclist t.vtype vs in
    try
      BDB_raw.putlist t.bdb (Type.marshall_key t.ktype k "putlist") tclist;
      Tclist.del tclist
    with e -> Tclist.del tclist

  let range t ?bkey ?binc ?ekey ?einc ?max () =
    let marshall_key = function
      | None -> None
      | Some k -> Some (Type.marshall_key t.ktype k "range") in
    let bkey = marshall_key bkey in
    let ekey = marshall_key ekey in
    Type.unmarshall_tclist t.ktype
      (BDB_raw.range t.bdb ?bkey ?binc ?ekey ?einc ?max ())

  let rnum t = BDB.rnum t.bdb
  let setcache t ?lcnum ?ncnum () = BDB.setcache t.bdb ?lcnum ?ncnum ()
  let setdfunit t dfunit = BDB.setdfunit t.bdb dfunit
  let setxmsiz t xmsiz = BDB.setxmsiz t.bdb xmsiz
  let sync t = BDB.sync t.bdb
  let tranabort t = BDB.tranabort t.bdb
  let tranbegin t = BDB.tranbegin t.bdb
  let trancommit t = BDB.trancommit t.bdb

  let tune t ?lmemb ?nmemb ?bnum ?apow ?fpow ?opts () =
    BDB.tune t.bdb ?lmemb ?nmemb ?bnum ?apow ?fpow ?opts ()

  let vanish t = BDB.vanish t.bdb
  let vnum t k = BDB_raw.vnum t.bdb (Type.marshall_key t.ktype k "vnum")
  let vsiz t k = BDB_raw.vsiz t.bdb (Type.marshall_key t.ktype k "vsiz")
end

module BDBCUR =
struct
  module BDBCUR_raw = BDBCUR.Fun (Cstr_cstr)

  type ('k, 'v) t = {
    bdbcur : BDBCUR.t;
    ktype : 'k Type.t;
    vtype : 'v Type.t;
  }

  let new_ bdb = {
    bdbcur = BDBCUR.new_ bdb.BDB.bdb;
    ktype = bdb.BDB.ktype;
    vtype = bdb.BDB.vtype;
  }

  let first t =
    (* first key should always be type_desc hash key *)
    BDBCUR.first t.bdbcur;
    BDBCUR.next t.bdbcur

  let jump t k =
    BDBCUR_raw.jump t.bdbcur (Type.marshall_key t.ktype k "jump")

  let key t =
    let cstr = BDBCUR_raw.key t.bdbcur in
    try
      let k = t.ktype.Type.unmarshall cstr in
      Cstr.del cstr;
      k
    with e -> Cstr.del cstr; raise e

  let last t = BDBCUR.last t.bdbcur
  let next t = BDBCUR.next t.bdbcur
  let out t = BDBCUR.out t.bdbcur

  let prev t =
    (* check to see if we've moved onto the type_desc hash key *)
    BDBCUR.prev t.bdbcur;
    let (k, klen) as cstr = BDBCUR_raw.key t.bdbcur in
    try
      if Type.is_type_desc_hash_key k klen
      then BDBCUR.prev t.bdbcur;
      Cstr.del cstr
    with e -> Cstr.del cstr; raise e

  let put t ?cpmode v = BDBCUR_raw.put t.bdbcur ?cpmode (t.vtype.Type.marshall v)

  let val_ t =
    let cstr = BDBCUR_raw.val_ t.bdbcur in
    try
      let v = t.vtype.Type.unmarshall cstr in
      Cstr.del cstr;
      v
    with e -> Cstr.del cstr; raise e
end

module FDB =
struct
  module FDB_raw = FDB.Fun (Cstr_cstr)

  type 'v t = {
    fdb : FDB.t;
    vtype : 'v Type.t;
    mutable width : int32;
  }

  let to_raw_key k func =
    match k with
      | _ when k = FDB.id_max || k = FDB.id_next -> k
      | _ when k = FDB.id_min || k = FDB.id_prev || k = 0L->
          (* we can't easily support min or prev since we take the 1L slot *)
          raise (Error (Einvalid, func, "invalid operation"))
      | _ -> Int64.succ k

  let of_raw_key k = Int64.pred k

  let marshall t v func =
    let (_, len) as vm = t.vtype.Type.marshall v in
    if Int32.of_int len > t.width
    then raise (Error (Einvalid, func, "marshalled value exceeds width"));
    vm

  let check_width vtype width =
    if width < Int32.of_int (String.length (Type.type_desc_hash vtype))
    then raise (Error (Einvalid, "open_", "width too small"))

  let open_ ?omode ?width vtype fn =
    let fdb = FDB.new_ () in
    begin match width with
      | None -> ()
      | Some width ->
          check_width vtype width;
          FDB.tune fdb ~width ()
    end;
    FDB.open_ fdb ?omode fn;
    let width = FDB.width fdb in
    let hash = Type.type_desc_hash vtype in
    begin try
      if hash <> FDB.get fdb 1L
      then begin
        FDB.close fdb;
        raise (Error (Einvalid, "open_", "bad type_desc hash"))
      end
    with Error (Enorec, _, _) ->
      (* XXX maybe should check that this is a fresh db? *)
      FDB.put fdb 1L hash;
    end;
    {
      fdb = fdb;
      vtype = vtype;
      width = width;
    }


  let close t = FDB.close t.fdb
  let copy t fn = FDB.copy t.fdb fn
  let fsiz t = FDB.fsiz t.fdb

  let get t k =
    let cstr = FDB_raw.get t.fdb (to_raw_key k "get") in
    try
      let v = t.vtype.Type.unmarshall cstr in
      Cstr.del cstr;
      v
    with e -> Cstr.del cstr; raise e

  let iterinit t =
    FDB.iterinit t.fdb;
    ignore (FDB.iternext t.fdb)

  let iternext t =
    of_raw_key (FDB.iternext t.fdb)

  let optimize t ?width ?limsiz () =
    (* XXX maybe should not be able to shrink the width. or we should check width of every record? *)
    FDB.optimize t.fdb ?width ?limsiz ();
    match width with
      | None -> ()
      | Some width ->
          check_width t.vtype width;
          t.width <- width

  let out t k =
    FDB.out t.fdb (to_raw_key k "out")

  let path t = FDB.path t.fdb

  let put t k v =
    FDB_raw.put t.fdb (to_raw_key k "put") (marshall t v "put")

  let putkeep t k v =
    FDB_raw.putkeep t.fdb (to_raw_key k "putkeep") (marshall t v "putkeep")

  let range t ?lower ?upper ?max () =
    let lower = match lower with None -> Some 2L | Some k -> Some (to_raw_key k "range") in
    let upper = match upper with None -> None | Some k -> Some (to_raw_key k "range") in
    let range = FDB.range t.fdb ?lower ?upper ?max () in
    Array.iteri (fun i k -> range.(i) <- of_raw_key k) range;
    range

  let rnum t = FDB.rnum t.fdb
  let sync t = FDB.sync t.fdb
  let tranabort t = FDB.tranabort t.fdb
  let tranbegin t = FDB.tranbegin t.fdb
  let trancommit t = FDB.trancommit t.fdb

  let tune t ?width ?limsiz () =
    begin match width with
      | None -> ()
      | Some width -> check_width t.vtype width
    end;
    FDB.tune t.fdb ?width ?limsiz ()

  let vanish t = FDB.vanish t.fdb

  let vsiz t k =
    FDB.vsiz t.fdb (to_raw_key k "vsiz")
end

module HDB =
struct
  module HDB_raw = HDB.Fun (Cstr_cstr) (Tclist_tclist)

  type ('k, 'v) t = {
    hdb : HDB.t;
    ktype : 'k Type.t;
    vtype : 'v Type.t;
  }

  let open_ ?omode ktype vtype fn =
    let hdb = HDB.new_ () in
    HDB.open_ hdb ?omode fn;
    let hash = Type.type_desc_hash ktype ^ Type.type_desc_hash vtype in
    begin try
      if hash <> HDB.get hdb Type.type_desc_hash_key
      then begin
        HDB.close hdb;
        raise (Error (Einvalid, "open_", "bad type_desc hash"))
      end
    with Error (Enorec, _, _) ->
      (* XXX maybe should check that this is a fresh db? *)
      HDB.put hdb Type.type_desc_hash_key hash;
    end;
    {
      hdb = hdb;
      ktype = ktype;
      vtype = vtype;
    }

  let close t = HDB.close t.hdb
  let copy t fn = HDB.copy t.hdb fn
  let fsiz t = HDB.fsiz t.hdb

  let get t k =
    let cstr = HDB_raw.get t.hdb (Type.marshall_key t.ktype k "get") in
    try
      let v = t.vtype.Type.unmarshall cstr in
      Cstr.del cstr;
      v
    with e -> Cstr.del cstr; raise e

  let iterinit t = HDB.iterinit t.hdb

  let iternext t =
    let (k, klen) as cstr = HDB_raw.iternext t.hdb in
    let cstr =
      if Type.is_type_desc_hash_key k klen
      then (Cstr.del cstr; HDB_raw.iternext t.hdb)
      else cstr in
    let k = t.ktype.Type.unmarshall cstr in
    Cstr.del cstr;
    k

  let optimize t ?bnum ?apow ?fpow ?opts () = HDB.optimize t.hdb ?bnum ?apow ?fpow ?opts ()
  let out t k = HDB_raw.out t.hdb (Type.marshall_key t.ktype k "out")
  let path t = HDB.path t.hdb
  let put t k v = HDB_raw.put t.hdb (Type.marshall_key t.ktype k "put") (t.vtype.Type.marshall v)
  let putasync t k v = HDB_raw.putasync t.hdb (Type.marshall_key t.ktype k "putasync") (t.vtype.Type.marshall v)
  let putkeep t k v = HDB_raw.putkeep t.hdb (Type.marshall_key t.ktype k "putkeep") (t.vtype.Type.marshall v)
  let rnum t = HDB.rnum t.hdb
  let setcache t rcnum = HDB.setcache t.hdb rcnum
  let setdfunit t dfunit = HDB.setdfunit t.hdb dfunit
  let setxmsiz t xmsiz = HDB.setxmsiz t.hdb xmsiz
  let sync t = HDB.sync t.hdb
  let tranabort t = HDB.tranabort t.hdb
  let tranbegin t = HDB.tranbegin t.hdb
  let trancommit t = HDB.trancommit t.hdb
  let tune t ?bnum ?apow ?fpow ?opts () = HDB.tune t.hdb ?bnum ?apow ?fpow ?opts ()
  let vanish t = HDB.vanish t.hdb
  let vsiz t k = HDB_raw.vsiz t.hdb (Type.marshall_key t.ktype k "vsiz")
end
