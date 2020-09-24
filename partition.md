# Postgres 12 Partitioning and ORCA

# Feature Parity
## Static Pruning
## Runtime Pruning
## Handling more than one level of partitioning
## Partial Scans with Indexes and Foreign Tables

# More Possibilities
Things that ORCA doesn't do, but we've wanted to do for a long time.

## Combined static and runtime pruning

Motivating example (taken from [gporca issue 565][gporca-issue-565])

[gporca-issue-565]: https://github.com/greenplum-db/gporca/issues/565

## "Intersecting" multiple partition selectors
## Proper runtime pruning under Nest Loop
## Hetero

# Setup

```sql
CREATE TABLE grandma (a int, b int, pk int) PARTITION BY RANGE(pk);
CREATE TABLE mom PARTITION OF grandma FOR VALUES FROM (0) TO (10);
CREATE TABLE aunt PARTITION OF grandma FOR VALUES FROM (-10) TO (0);

CREATE TABLE abuela (a int, b int, pk int) PARTITION BY LIST(pk);
CREATE TABLE mama PARTITION OF abuela FOR VALUES IN (40, 42);
CREATE TABLE tia PARTITION OF abuela FOR VALUES IN (-3, -2, -1);
```

# Postgres 12 init pruning over list partitioned table:

```sql
SELECT * FROM abuela WHERE pk NOT IN (40, 42, 44);
```

EXPLAIN:
```
 Append
   Subplans Removed: 1
   ->  Seq Scan on tia
         Filter: (pk <> ALL (ARRAY[$1, $2, $3]))
```

```
:part_prune_info
   {PARTITIONPRUNEINFO
   :prune_infos ((
      {PARTITIONEDRELPRUNEINFO
      :rtindex 1
      :present_parts (b 0 1)
      :nparts 2
      :subplan_map  0 1
      :subpart_map  -1 -1
      :relid_map  67390 67387
      :initial_pruning_steps (
         {PARTITIONPRUNESTEPOP
         :step.step_id 0
         :opstrategy 0
         :exprs (
            {PARAM
            :paramkind 0
            :paramid 1
            :paramtype 23
            :paramtypmod -1
            :paramcollid 0
            :location 70
            }
         )
         :cmpfns (o 351)
         :nullkeys (b)
         }
         {PARTITIONPRUNESTEPOP
         :step.step_id 1
         :opstrategy 0
         :exprs (
            {PARAM
            :paramkind 0
            :paramid 2
            :paramtype 23
            :paramtypmod -1
            :paramcollid 0
            :location 74
            }
         )
         :cmpfns (o 351)
         :nullkeys (b)
         }
         {PARTITIONPRUNESTEPOP
         :step.step_id 2
         :opstrategy 0
         :exprs (
            {PARAM
            :paramkind 0
            :paramid 3
            :paramtype 23
            :paramtypmod -1
            :paramcollid 0
            :location 78
            }
         )
         :cmpfns (o 351)
         :nullkeys (b)
         }
         {PARTITIONPRUNESTEPCOMBINE
         :step.step_id 3
         :combineOp 1
         :source_stepids (i 0 1 2)
         }
      )
      :exec_pruning_steps <>
      :execparamids (b)
      }
   ))
   :other_subplans (b)
   }
```

# Notes & Feedback

# Parking Lot

Questions:

1. How does "flattening" work in planner?
1. How much of the existing machinary benefit ORCA's run time pruning (hint: join, setop)
1. `SELECT pk FROM foo_partitioned`
1. `SELECT pk FROM foo_partitioned WHERE pk = 2`
1. `SELECT pk FROM foo_partitioned WHERE pk BETWEEN 2 AND 4`
1. `SELECT pk FROM foo_partitioned JOIN bar ON pk = bar.c`
1. `SELECT pk FROM foo_partitioned JOIN bar ON pk BETWEEN bar.c AND bar.d`
