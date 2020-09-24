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

CREATE TABLE grandpa (a int, b int, pk int) PARTITION BY RANGE(b);
CREATE TABLE dad PARTITION OF grandpa FOR VALUES FROM (0) TO (20) PARTITION BY RANGE(pk);
CREATE TABLE me PARTITION OF dad FOR VALUES FROM (0) TO (43);
CREATE TABLE bro PARTITION OF dad FOR VALUES FROM (-43) TO (0);
CREATE TABLE older_uncle PARTITION OF grandpa FOR VALUES FROM (20) TO (40) PARTITION BY RANGE(pk);
CREATE TABLE aaron PARTITION OF older_uncle FOR VALUES FROM (0) TO (2);
CREATE TABLE abel PARTITION OF older_uncle FOR VALUES FROM (4) TO (6);
CREATE TABLE younger_uncle PARTITION OF grandpa FOR VALUES FROM (40) TO (60);

SELECT oid, oid::regclass
FROM pg_class
WHERE oid = ANY
  (ARRAY['grandma', 'mom', 'aunt', 'abuela', 'mama', 'tia', 'grandpa', 'dad', 'me', 'bro', 'older_uncle', 'aaron', 'abel', 'younger_uncle']::regclass[])
ORDER BY 1;
```

Sample output:

```
  oid  |      oid
-------+---------------
 67877 | grandma
 67880 | mom
 67883 | aunt
 67886 | abuela
 67889 | mama
 67892 | tia
 67895 | grandpa
 67898 | dad
 67901 | me
 67904 | bro
 67907 | older_uncle
 67910 | aaron
 67913 | abel
 67916 | younger_uncle
(14 rows)
```

# When is pruneinfos length > 1 in outerlist? Inner list?

```sql
SELECT *
FROM (
	SELECT *
	FROM grandma
	UNION ALL
	SELECT *
	FROM grandpa
) t
WHERE pk > $1;
```

<details>
<summary>Annotated plan snipet</summary>

```
:part_prune_info
   {PARTITIONPRUNEINFO
   :prune_infos ((
      {PARTITIONEDRELPRUNEINFO
      :rtindex 4 # rti=4: grandma
      :present_parts (b 0 1)
      :nparts 2
      :subplan_map  0 1 # the positions of the scan plans for surviving partitions
      :subpart_map  -1 -1 # none of the partitions need further pruning
      :relid_map  67883 67880 # aunt mom (in range order, not oid order)
      :initial_pruning_steps (
         {PARTITIONPRUNESTEPOP
         :step.step_id 0
         :opstrategy 5 # > $1
         :exprs (
            {PARAM
            :paramkind 0
            :paramid 1
            :paramtype 23
            :paramtypmod -1
            :paramcollid 0
            :location 112
            }
         )
         :cmpfns (o 351) # btint4cmp(int,int)
         :nullkeys (b)
         }
      )
      :exec_pruning_steps <>
      :execparamids (b)
      }
   )
   (
      {PARTITIONEDRELPRUNEINFO
      :rtindex 5 # rti=5: grandpa
      :present_parts (b 0 1 2)
      :nparts 3
      :subplan_map  -1 -1 6 # the first two (dad, older_uncle) need further pruning (subpartitions), while younger_uncle (the third) will reach a scan plan (leaf)
      :subpart_map  1 2 -1 # ditto
      :relid_map  67898 67907 67916 # dad, older_uncle, younger_uncle
      :initial_pruning_steps <>
      :exec_pruning_steps <>
      :execparamids (b)
      }
      {PARTITIONEDRELPRUNEINFO
      :rtindex 8 # rti=8: dad
      :present_parts (b 0 1)
      :nparts 2
      :subplan_map  2 3 # after pruning, the surviving partitions will be scanned (each is a leaf)
      :subpart_map  -1 -1
      :relid_map  67904 67901 # bro, me (in range order)
      :initial_pruning_steps (
         {PARTITIONPRUNESTEPOP
         :step.step_id 0
         :opstrategy 5
         :exprs (
            {PARAM
            :paramkind 0
            :paramid 1
            :paramtype 23
            :paramtypmod -1
            :paramcollid 0
            :location 112
            }
         )
         :cmpfns (o 351)
         :nullkeys (b)
         }
      )
      :exec_pruning_steps <>
      :execparamids (b)
      }
      {PARTITIONEDRELPRUNEINFO
      :rtindex 11 # rti=11: older_uncle
      :present_parts (b 0 1)
      :nparts 2
      :subplan_map  4 5 # each is a leaf
      :subpart_map  -1 -1
      :relid_map  67910 67913 # aaron abel
      :initial_pruning_steps (
         {PARTITIONPRUNESTEPOP
         :step.step_id 0
         :opstrategy 5
         :exprs (
            {PARAM
            :paramkind 0
            :paramid 1
            :paramtype 23
            :paramtypmod -1
            :paramcollid 0
            :location 112
            }
         )
         :cmpfns (o 351)
         :nullkeys (b)
         }
      )
      :exec_pruning_steps <>
      :execparamids (b)
      }
   ))
   :other_subplans (b)
   }
}
```

</details>

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

<details>
<summary>Details inside of `Append`</summary>

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

</details>

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
