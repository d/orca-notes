### `ALTER TABLE ONLY ... ADD CONSTRAINT ...` proposal
`ALTER TABLE ONLY ... ADD CONSTRAINT ...` should not recurse into partition children 

## Context
**GIVEN** we disallow named index-backed (think `UNIQUE`) constraints on partition table DDL

**IN ORDER TO** provide precise control to `pg_dump` on a partition table created on Greenplum 6 with constraints

we need to allow it in a limited form (temporarily relaxing the uniformity of `UNIQUE` constraints) during binary upgrade

## Example

1. On a Greenplum 6 cluster (after story <https://www.pivotaltracker.com/story/show/161023648>), the following DDL

   ```sql
   CREATE TABLE pt (
       a integer,
       b integer,
       UNIQUE (a, b)
   ) DISTRIBUTED BY (a) PARTITION BY RANGE(b)
     (
     PARTITION alpha  END (3),
     PARTITION beta START (3)
     );

   SELECT conrelid::regclass, conname, conindid::regclass
   FROM pg_constraint
   WHERE
   contype <> 'c'
   AND
   conrelid IN (
       SELECT 'pt'::regclass
       UNION ALL
       SELECT inhrelid
       FROM pg_inherits
       WHERE inhparent = 'pt'::regclass
   );

   ```

   Can put the database in a unpredictable state. One possible end state [^footnote_1] is:

   ```
       conrelid    |          conname         |        conindid
   ----------------+--------------------------+-------------------------
    pt             | pt_a_b_key1              | pt_a_b_key1
    pt_1_prt_alpha | pt_1_prt_alpha_a_b_key1  | pt_1_prt_alpha_a_b_key1
    pt_1_prt_beta  | pt_1_prt_beta_a_b_key2   | pt_1_prt_beta_a_b_key2
   (3 rows)
   ```

1. `pg_upgrade` currently dumps the following DDL for table `pt`:

   ```sql
   CREATE TABLE pt (a integer, b integer) DISTRIBUTED BY (a)
   PARTITION BY RANGE(b) (PARTITION alpha  END (3), PARTITION beta START (3));

   ALTER TABLE ONLY pt
       ADD CONSTRAINT pt_a_b_key1 UNIQUE (a, b);

   ```
   
   **FIXME** elaborate why this DDL is bad.

## Footnote
1. [^footnote_1] pre-condition:

   ```sql

   -- given that we squat some names
   CREATE TYPE pt_a_b_key AS (yolo int);
   CREATE TYPE pt_1_prt_alpha_a_b_key AS (yolo int);
   CREATE TYPE pt_1_prt_beta_a_b_key AS (yolo int);
   CREATE TYPE pt_1_prt_beta_a_b_key1 AS (yolo int);
   ```


## FIXME
JZ's self-doubt: What should happen to regular `pg_dump`? Won't a regular restore become a problem too?
