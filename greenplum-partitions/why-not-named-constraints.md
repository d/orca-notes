## What's wrong with named constraints
What's wrong with named (index-backed) constraint on partition tables like the following:

```sql
CREATE TABLE pt (
    a integer,
    b integer,
    CONSTRAINT yolo UNIQUE (a, b)
) DISTRIBUTED BY (a) PARTITION BY RANGE(b)
  (
  PARTITION alpha  END (3),
  PARTITION beta START (3)
  );
```

TL;DR once an object (index) is created, theirs name _can_ change. Which means that the best we could do is a _syntactic sugar_. **Named constraints can *never* be a desugared syntax.**

## Can't we just have a consistent naming scheme?
No we can't. Let's assume you propose that for the DDL above, you want to combine the table / partition name with the constraint name:

```
    conrelid    |       conname       |     indexrelid
----------------+---------------------+---------------------
 pt             | pt_yolo             | pt_yolo
 pt_1_prt_alpha | pt_1_prt_alpha_yolo | pt_1_prt_alpha_yolo
 pt_1_prt_beta  | pt_1_prt_beta_yolo  | pt_1_prt_beta_yolo
(3 rows)

```

To enable named constraints as a *desugared* syntax, we need to be able to map a catalog state of the above to a single DDL (think: `pg_dump`).
But that's impossible:

1. It's very tempting to infer the `CONSTRAINT yolo` by looking at the table name (`pt`) and the index name (`pt_yolo`). But...
1. What if an index on a leaf table gets renamed (example follows)? You easily get an inference conflict.

   ```
       conrelid    |       conname       |     indexrelid
   ----------------+---------------------+---------------------
    pt             | pt_yolo             | pt_yolo
    pt_1_prt_alpha | pt_1_prt_charlie    | pt_1_prt_charlie
    pt_1_prt_beta  | pt_1_prt_beta_yo    | pt_1_prt_beta_yo
   (3 rows)
   
   ```
1. Should we rename indexes as a partiton joins the hierarchy (think: `EXCHANGE PARTITION`)?
1. There's also a usability issue here: letting the user specify `CONSTRAINT yolo`, and then creating objects not really named `yolo` (and we cannot reasonably refer to in the future using the name `yolo`) is a surprise.
