CREATE FUNCTION relations_of(root regclass)
    RETURNS TABLE
            (
                rel regclass
            )
    LANGUAGE SQL
    STABLE
AS
$fn$
WITH RECURSIVE t(rel) AS (
    SELECT root
    UNION ALL
    SELECT inhrelid FROM pg_inherits JOIN t ON inhparent = rel
)
SELECT rel FROM t;
$fn$;

CREATE FUNCTION describe(pg_constraint) RETURNS text
    LANGUAGE SQL
    STRICT STABLE AS
$fn$
SELECT 'con:' || $1.conname || ' (of ' || $1.conrelid::regclass || ')';
$fn$;

CREATE FUNCTION describe(pg_rewrite) RETURNS text
    LANGUAGE SQL
    STRICT STABLE AS
$fn$
SELECT 'view:' || $1.ev_class::regclass;
$fn$;

CREATE FUNCTION describe(pg_type, regtype) RETURNS text
    LANGUAGE SQL
    STRICT STABLE AS
$fn$
SELECT 'typ:' || $2;
$fn$;

CREATE FUNCTION describe(pg_namespace) RETURNS text
    LANGUAGE SQL
    STRICT STABLE AS
$fn$
SELECT 'nsp:' || $1.nspname;
$fn$;

CREATE FUNCTION describe(pg_class, regclass, subid int) RETURNS text
    LANGUAGE SQL
    STRICT STABLE AS
$fn$
SELECT CASE
           WHEN relkind IN ('i', 'I') THEN 'idx:' || rel.relname
           ELSE COALESCE('col:' || rel.relname || '.' || attname,
                         'rel:' || rel.relname) END
FROM (VALUES ($2, $1.relname, $1.relkind, $3)) rel(oid, relname, relkind, attnum)
         LEFT JOIN pg_attribute att
                   ON $2 = att.attrelid AND rel.attnum = att.attnum
    ;
$fn$;

CREATE FUNCTION describe(classid regclass, objid oid, objsubid int) RETURNS text
    LANGUAGE SQL
    STABLE AS
$fn$
SELECT COALESCE(describe(con), describe(rel, rel.oid, objsubid), describe(rule),
                describe(nsp), describe(typ, typ.oid))
FROM (VALUES ($1, $2, $3)) t(classid, objid, objsubid)
         LEFT JOIN pg_constraint con
                   ON 'pg_constraint'::regclass = classid AND con.oid = objid
         LEFT JOIN pg_class rel
                   ON 'pg_class'::regclass = classid AND rel.oid = objid
         LEFT JOIN pg_type typ
                   ON 'pg_type'::regclass = classid AND typ.oid = objid
         LEFT JOIN pg_rewrite rule
                   ON 'pg_rewrite'::regclass = classid AND rule.oid = objid
         LEFT JOIN pg_namespace nsp
                   ON 'pg_namespace'::regclass = classid AND nsp.oid = objid
    ;
$fn$;

CREATE FUNCTION dependents_of(root regclass)
    RETURNS TABLE
            (
                classid regclass,
                objid   oid
            )
    LANGUAGE SQL
    STABLE
AS
$fn$
WITH RECURSIVE t(classid, objid, refclassid, refobjid, refobjsubid, deptype) AS (
    SELECT dep.classid, dep.objid, dep.refclassid, dep.refobjid, dep.refobjsubid, dep.deptype
    FROM pg_depend dep
    WHERE 'pg_class'::regclass = dep.refclassid
    AND dep.refobjid = $1
    UNION
    SELECT dep.classid, dep.objid, dep.refclassid, dep.refobjid, dep.refobjsubid, dep.deptype
    FROM pg_depend dep JOIN t ON
        t.classid = dep.refclassid
        AND t.objid = dep.refobjid
)
SELECT classid, objid
FROM t
GROUP BY classid, objid
$fn$;

CREATE FUNCTION constraints_of(root regclass)
    RETURNS TABLE
            (
                relid    regclass,
                contype  "char",
                conname  name,
                conindid regclass
            )
    LANGUAGE SQL
    STABLE
AS
$fn$
SELECT con.conrelid, con.contype, con.conname, con.conindid
FROM pg_constraint con
WHERE contype IN ('u', 'p')
  AND conrelid IN (SELECT * FROM relations_of(root));
$fn$;

CREATE FUNCTION indices_of(root regclass)
    RETURNS TABLE
            (
                relid      regclass,
                indexrelid regclass
            )
    LANGUAGE SQL
    STABLE
AS
$fn$
SELECT ind.indrelid, ind.indexrelid
FROM pg_index ind
WHERE indrelid IN (SELECT * FROM relations_of(root));
$fn$;
