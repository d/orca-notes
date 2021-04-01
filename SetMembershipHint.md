# Set Membership Hints For Motions

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

   1. Most nodes just pass the request down, verbatim

   1. Motion receiver will act upon the request by actually messaging all its
      senders

   1. Shared Scan / Material / Sort should drop this on the floor

## FAQ

### Should this be a pure-executor thing? Why is the optimizers involved?

Like most optimizations, this is not a no-brainer (it has non-trivial
overhead). Generating the digest from hash table takes time on the receiver
side, but more significantly, this adds a per-tuple overhead on the motion
sender side. It is the optimizer's job to decide whether the gain is worth the
overhead.

### We can push the set-membership filter below motion senders, right?

Not Really.

1. The filter is meant to be *per-receiver*, so the motion sender is in the
   best position to maintain these per-receiver information.

1. Adding to the *per-receiver* point, if this is a broadcast motion, a random
   motion, or a gather motion, the only node in the slice that knows where a
   tuple is going would be the top node (the motion sender)

1. The plan node for the motion node will also need additional hash opclasses
   (or directly the hashfn oid I guess). Having this filtering below motion
   means we need to proliferate this everywhere (let alone the iffiness of
   non-redistribute motion)


## Open Questions

We should be able to "combine" multiple hints, as in the following case:

```sql
EXPLAIN (COSTS OFF)
SELECT
FROM foo JOIN bar ON b = c JOIN baz ON e = c;
```

With a general plan shape of:

```
 Gather Motion 3:1  (slice1; segments: 3)
   ->  Hash Join (Jacob)
         Hash Cond: (bar.c = baz.e)
         ->  Hash Join (Joseph)
               Hash Cond: (foo.b = bar.c)
               ->  Redistribute Motion 3:3  (slice2; segments: 3)
                     Hash Key: foo.b
                     ->  Seq Scan on foo
               ->  Hash
                     ->  Seq Scan on bar
         ->  Hash
               ->  Seq Scan on baz
```

1. Here we see that the Join atop `bar` "Joseph" will hint at its outer child
   with a set membership filter generated from the contents of `bar`

1. Also notice "Joseph" have received an earlier hint from the Hash Join above
   it, "Jacob", generated from the contents of scanning `baz`

1. Basic idea, most nodes won't "remember" the hints they received before, they
   just do the normal pass-down-until-it-hits-motion-receiver thing. But the
   motion sender will be in a position to combine these filters.

1. This adds a requirement that the set membership needs to have a
   representation that is conducive to merging. (For bloom filters with
   parameters `(n,k)`, we need to fix both of them to be able to quickly merge;
   for a simple power-of-two hash bits representation, we need to fix the
   power-of-two)
