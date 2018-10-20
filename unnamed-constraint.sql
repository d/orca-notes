-- clean up / set up
DROP SCHEMA IF EXISTS yolo CASCADE;
CREATE SCHEMA yolo;
set search_path to yolo;

-- given that we squat some names
-- squat names for 6
CREATE TYPE pt_a_b_key AS (yolo int);
CREATE TYPE pt_1_prt_alpha_a_b_key AS (yolo int);
CREATE TYPE pt_1_prt_beta_a_b_key AS (yolo int);
CREATE TYPE pt_1_prt_beta_a_b_key1 AS (yolo int);
-- squat names for 5
CREATE TYPE pt_a_key AS (yolo int);
CREATE TYPE pt_1_prt_alpha_a_key AS (yolo int);
CREATE TYPE pt_1_prt_beta_a_key AS (yolo int);
CREATE TYPE pt_1_prt_beta_a_key1 AS (yolo int);

-- and

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

CREATE TABLE pt (
    a integer,
    b integer,
    UNIQUE (a, b)
) DISTRIBUTED BY (a) PARTITION BY RANGE(b)
  (
  PARTITION alpha  END (3),
  PARTITION beta START (3)
  );

-- mess with 6
BEGIN;
  ALTER INDEX pt_a_b_key1 RENAME TO lol;
  ALTER INDEX lol RENAME TO pt_a_b_key1;
END;

-- mess with 5
BEGIN;
  ALTER INDEX pt_a_key1 RENAME TO lol;
  ALTER INDEX lol RENAME TO pt_a_key1;
END;

SELECT * FROM constraints_and_indices_for('pt');

-- erase my tracks
DROP TYPE pt_a_b_key;
DROP TYPE pt_1_prt_alpha_a_b_key;
DROP TYPE pt_1_prt_beta_a_b_key;
DROP TYPE pt_1_prt_beta_a_b_key1;
