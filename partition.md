### plan time pruning

* *I think* uses `constraint_exclusiong=partition` **fact check this**

### runtime pruning

`get_partition_for_tuple`

#####

`PartitionPruneState`: `ExecCreatePartitionPruneState`
`PartitionKey`
`PartitionDesc`
`PlannedStmt::appendRelations`

### goals

Questions:

1. How does "flattening" work in planner?
1. How much of the existing machinary benefit ORCA's run time pruning (hint: join, setop)
1. `SELECT pk FROM foo_partitioned`
1. `SELECT pk FROM foo_partitioned WHERE pk = 2`
1. `SELECT pk FROM foo_partitioned WHERE pk BETWEEN 2 AND 4`
1. `SELECT pk FROM foo_partitioned JOIN bar ON pk = bar.c`
1. `SELECT pk FROM foo_partitioned JOIN bar ON pk BETWEEN bar.c AND bar.d`
