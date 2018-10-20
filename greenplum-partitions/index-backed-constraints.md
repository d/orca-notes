## (Index-Backed) Constraints Are Not Dumpable

```sql
CREATE TABLE t (a int, b int, CONSTRAINT yolo UNIQUE (a, b)) DISTRIBUTED BY (a);
```
