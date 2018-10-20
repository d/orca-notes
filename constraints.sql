-- inspection function to help us look at the catalog
CREATE FUNCTION constraints_and_indices_for(IN t regclass, OUT relation regclass, OUT "constraint" name, OUT index regclass) RETURNS SETOF RECORD
LANGUAGE sql STABLE STRICT AS
$fn$
SELECT con.conrelid::regclass, con.conname, ind.indexrelid::regclass
FROM pg_constraint con
INNER JOIN pg_depend dep ON
  dep.classid = 'pg_class'::regclass
  AND
  dep.refclassid = 'pg_constraint'::regclass
  AND
  dep.refobjid = con.oid
  AND
  dep.deptype = 'i'
  AND
  con.contype <> 'c'
  AND
  con.conrelid IN (
    SELECT $1
    UNION ALL
    SELECT inhrelid
    FROM pg_inherits
    WHERE inhparent = $1
  )
INNER JOIN pg_index ind ON
  dep.objid = indexrelid
  AND
  con.conrelid = indrelid
$fn$;

-- story time
CREATE TABLE t (a int, b int, CONSTRAINT yolo UNIQUE (a, b)) DISTRIBUTED BY (a);
SELECT * FROM constraints_and_indices_for('t');

ALTER TABLE t RENAME TO r;
CREATE TABLE r_a_key();
CREATE TABLE r_a_b_key();
CREATE TABLE yolo();
SELECT * FROM constraints_and_indices_for('r');
