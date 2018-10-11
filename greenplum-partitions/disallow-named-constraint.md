## Disallow named constraints when creating / altering partition tables

## DON'T START THIS STORY UNTIL WE AGREE ON
Jacob needs to fist fight Jesse on Monday (Oct 9, 2018)
But seriously, we need to be on the same page about:
1. (Jacob) What's wrong with named constraint? Can't we make it deterministic? [(Jesse) No.](why-not-named-constraints.md)
1. (Jesse) No that's gonna make `pg_dump` on unnamed constraints wrong

## Context: Desired end state for index-backed constraints on partition tables
* `EXCLUDE`, `PRIMARY KEY` and `UNIQUE`constraints are named identically as their supporting indices
* **TODO** What should partition tables do?
* This should enable a simpler `pg_upgrade`:
  1. `pg_upgrade` should refuse to upgrade a cluster that has `UNIQUE` or `PRIMARY KEY` constraints (also `EXCLUDE` constraints if we don't fix 6.0...) that are differently named from the indices (probably file a story on figuring out how to detect that in 4.3 and 5.X)
  1. `pg_upgrade` can assume that the old cluster is "good" (constraint names = index names)
  1. (optional) `pg_upgrade` can generate a pair of SQL scripts:
     - "drop constraints" SQL to suggest turning a non-conforming database to a "good" one
     - a companion "recreate constraints" SQL script that puts the integrity constraints back (not guaranteed to have the same names though)


## Actual story
Given our vision on eventually identically naming index-backed constraints with their indices, we need to disallow the following on partition tables:

1. named colulmn constraints:
   - `CREATE TABLE pt (a int, b int CONSTRAINT yolo UNIQUE) PARTITION BY range(b) (END (10));`
1. named table constraint at table creation:
   - `CREATE TABLE pt (a int, b int, CONSTRAINT yolo UNIQUE(a,b)) DISTRIBUTED BY (a) PARTITION BY range(b) (END (10));`
1. adding named table cosntraint:
   - `ALTER TABLE pt ADD CONSTRAINT yolo UNIQUE (a,b);`


## Example to convince Jacob
Consider the following sequence of operation on Greenplum 5/6

```sql
-- given that we squat some names
CREATE TYPE pt_a_b_key AS (yolo int);
CREATE TYPE pt_1_prt_alpha_a_b_key AS (yolo int);
CREATE TYPE pt_1_prt_beta_a_b_key AS (yolo int);
CREATE TYPE pt_1_prt_beta_a_b_key1 AS (yolo int);

-- and

CREATE TABLE pt (
    a integer,
    b integer,
    UNIQUE (a, b)
) DISTRIBUTED BY (a) PARTITION BY RANGE(b)
  (
  PARTITION alpha  END (3),
  PARTITION beta START (3)
  );


CREATE FUNCTION constraints_and_indices_for(IN t regclass, OUT relation regclass, OUT "constraint" name, OUT index regclass) RETURNS SETOF RECORD
LANGUAGE plpgsql STABLE STRICT AS
$fn$

BEGIN

  RETURN QUERY
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
        SELECT t
        UNION ALL
        SELECT inhrelid
        FROM pg_inherits
        WHERE inhparent = t
      )
    INNER JOIN pg_index ind ON
      dep.objid = indexrelid
      AND
      con.conrelid = indrelid
  ;
END
$fn$;

SELECT * FROM constraints_and_indices_for('pt');

-- erase my tracks
DROP TYPE pt_a_b_key;
DROP TYPE pt_1_prt_alpha_a_b_key;
DROP TYPE pt_1_prt_beta_a_b_key;
DROP TYPE pt_1_prt_beta_a_b_key1;
```

Depending on the database state before the `CREATE TABLE`, the index names are not predictable:

```
    relation    | constraint |          index
----------------+------------+-------------------------
 pt             | pt_key     | pt_a_b_key1
 pt_1_prt_alpha | pt_key     | pt_1_prt_alpha_a_b_key1
 pt_1_prt_beta  | pt_key     | pt_1_prt_beta_a_b_key2
(3 rows)

```

## FAQ
1. [Why are you against named (index-backed) constraints on a partition table?](why-not-named-constraints.md)


## History
Spun out of an uber story <https://www.pivotaltracker.com/story/show/160911811>

