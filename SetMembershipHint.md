## Motivation

Set up:
```sql
CREATE TABLE foo (a int, b int);
CREATE TABLE bar (c int, d int);
CREATE TABLE baz (e int, f int);
```

```sql
EXPLAIN (COSTS OFF)
SELECT
FROM foo JOIN bar ON b = c;
```

Without loss of generality, this is an expected plan:

```
 Gather Motion 3:1  (slice1; segments: 3)
   ->  Hash Join
         Hash Cond: (foo.b = bar.c)
         ->  Redistribute Motion 3:3  (slice2; segments: 3)
               Hash Key: foo.b
               ->  Seq Scan on foo
         ->  Hash
               ->  Seq Scan on bar
```

## A Modest Proposal

1. A motion receiver can send a message out-of-band to all its sender peers,
   with necessary information to describe a set membership test. The semantics
   of this message is: "here's the subset of things I care about, send me
   everything in here".

1. This is a hint, which means that it can tolerate one-sided errors: false
   positives are acceptable, false negatives are not. (Plain speak: it's OK to
   give me more than what I ask for; it's not OK to miss anything I want).

1. This happens mid-flight, which means that the receiver keeps whatever was
   already in the receiving buffer, and the sender doesn't have to do "rewind".

1. There needs to be a new API in the executor alongside `ExecProcNode` so that
   `HashJoin` can pass down the hint to lower level executor nodes.

## Open Questions

We should be able to "combine" multiple hints, as in the following case:

```sql
EXPLAIN (COSTS OFF)
SELECT
FROM foo JOIN bar ON b = c JOIN baz ON f = c;
```

With a general plan shape of:

```
 Gather Motion 3:1  (slice1; segments: 3)
   ->  Hash Join (Jacob)
         Hash Cond: (bar.d = baz.e)
         ->  Redistribute Motion 3:3  (slice2; segments: 3)
               Hash Key: bar.d
               ->  Hash Join (Joseph)
                     Hash Cond: (foo.b = bar.c)
                     ->  Redistribute Motion 3:3  (slice3; segments: 3)
                           Hash Key: foo.b
                           ->  Seq Scan on foo
                     ->  Hash
                           ->  Seq Scan on bar
         ->  Hash
               ->  Seq Scan on baz
```

Here we see that the Join atop `bar` "Joseph"
