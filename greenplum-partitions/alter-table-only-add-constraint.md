### `ALTER TABLE ONLY ... ADD CONSTRAINT ...` proposal
`ALTER TABLE ONLY ... ADD CONSTRAINT ...` should not recurse into partition children 

## Context
**GIVEN** we [disallow](disallow-named-constraint.md) named index-backed (think `UNIQUE`) constraints on partition table DDL

**IN ORDER TO** provide precise control to `pg_dump` on a partition table created on Greenplum 6 with constraints

We need to allow it in a limited form (temporarily relaxing the uniformity of `UNIQUE` constraints)

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

   ```

   Can put the database in a unpredictable state. One possible end state [^wacky_ddl] is:

   ```sql

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

       conrelid    |          conname         |        conindid
   ----------------+--------------------------+-------------------------
    pt             | pt_a_b_key1              | pt_a_b_key1
    pt_1_prt_alpha | pt_1_prt_alpha_a_b_key2  | pt_1_prt_alpha_a_b_key2
    pt_1_prt_beta  | pt_1_prt_beta_a_b_key3   | pt_1_prt_beta_a_b_key3
   (3 rows)
   ```

1. `pg_upgrade` currently dumps the following DDL for table `pt`:

   ```sql
   CREATE TABLE pt (a integer, b integer) DISTRIBUTED BY (a)
   PARTITION BY RANGE(b) (PARTITION alpha  END (3), PARTITION beta START (3));

   ALTER TABLE pt
       ADD CONSTRAINT pt_a_b_key1 UNIQUE (a, b);

   ```

1. Ideally, you want to dump the above catalog state as:

   ```sql
   CREATE TABLE pt (a integer, b integer) DISTRIBUTED BY (a)
   PARTITION BY RANGE(b) (PARTITION alpha  END (3), PARTITION beta START (3));

   ALTER TABLE ONLY pt_1_prt_alpha ADD CONSTRAINT pt_1_prt_alpha_a_b_key1;
   ALTER TABLE ONLY pt_1_prt_beta ADD CONSTRAINT pt_1_prt_beta_a_b_key2;
   ALTER TABLE ONLY pt ADD CONSTRAINT pt_a_b_key1;
   ```


[^wacky_ddl]: How to get the database to the wacky state:

    ```sql
    -- squat some table names
    CREATE TYPE pt_a_b_key AS (yolo int);
    CREATE TYPE pt_1_prt_alpha_a_b_key AS (yolo int);
    CREATE TYPE pt_1_prt_alpha_a_b_key1 AS (yolo int);
    CREATE TYPE pt_1_prt_beta_a_b_key AS (yolo int);
    CREATE TYPE pt_1_prt_beta_a_b_key1 AS (yolo int);
    CREATE TYPE pt_1_prt_beta_a_b_key2 AS (yolo int);

    -- create table using unnamed constraint syntax
    CREATE TABLE pt (
        a integer,
        b integer,
        UNIQUE (a, b)
    ) DISTRIBUTED BY (a) PARTITION BY RANGE(b)
      (PARTITION alpha  END (3), PARTITION beta START (3));

    -- erase my tracks
    DROP TYPE pt_a_b_key;
    DROP TYPE pt_1_prt_alpha_a_b_key;
    DROP TYPE pt_1_prt_alpha_a_b_key1;
    DROP TYPE pt_1_prt_beta_a_b_key;
    DROP TYPE pt_1_prt_beta_a_b_key1;
    DROP TYPE pt_1_prt_beta_a_b_key2;
    ```
