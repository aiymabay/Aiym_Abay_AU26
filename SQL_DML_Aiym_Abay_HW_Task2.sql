/*
	Step 1. Create table_to_delete with 10 000 000 rows
*/
DROP TABLE IF EXISTS public.table_to_delete;
 
CREATE TABLE public.table_to_delete AS
SELECT	'veeeeeeery_long_string' || gen.x	AS col
FROM	generate_series(1, (10^7)::int) AS gen (x);	  --creates 10^7 rows, numbers 1 to 10 000 000
-- Result: SELECT 10000000, about 22 s
 
/*
	Step 2. Space consumption (this query is reused after every step)
	Same logic as the query from the task, written without SELECT * and with
	meaningful aliases.
*/
SELECT	rel_size.table_schema,
		rel_size.table_name,
		rel_size.row_estimate,
		rel_size.total_bytes,
		rel_size.index_bytes,
		rel_size.toast_bytes,
		rel_size.table_bytes,
		pg_size_pretty(rel_size.total_bytes)	AS total,
		pg_size_pretty(rel_size.index_bytes)	AS index,
		pg_size_pretty(rel_size.toast_bytes)	AS toast,
		pg_size_pretty(rel_size.table_bytes)	AS table
FROM	(SELECT rel_raw.*,
				rel_raw.total_bytes - rel_raw.index_bytes - COALESCE(rel_raw.toast_bytes, 0)	AS table_bytes
		 FROM	(SELECT cls.oid,
						nsp.nspname										AS table_schema,
						cls.relname										AS table_name,
						cls.reltuples									AS row_estimate,
						pg_total_relation_size(cls.oid)					AS total_bytes,
						pg_indexes_size(cls.oid)						AS index_bytes,
						pg_total_relation_size(cls.reltoastrelid)		AS toast_bytes
				 FROM	pg_catalog.pg_class cls
				 LEFT OUTER JOIN pg_catalog.pg_namespace nsp ON nsp.oid = cls.relnamespace
				 WHERE	cls.relkind = 'r'
				) AS rel_raw
		) AS rel_size
WHERE	rel_size.table_name LIKE '%table_to_delete%';
-- Result after creation: total 575 MB (602 415 104 bytes), table 575 MB, index 0 bytes, toast 8192 bytes
 
 
/*
	Step 3. DELETE one third of the rows
*/
DELETE FROM public.table_to_delete
WHERE	REPLACE(col, 'veeeeeeery_long_string', '')::int % 3 = 0;   -- removes 1/3 of all rows
-- 3a) Result: DELETE 3333333, execution time about 18 s
 
-- 3b) Space after DELETE: run the Step 2 query again
-- Result: total 575 MB (602 537 984 bytes). Nothing was freed; the size even grew by 122 880 bytes
-- (15 pages of 8 KB) because autovacuum created the free space map and visibility map of the
-- table, which pg_total_relation_size also counts.
-- Dead rows can be seen in the statistics:
SELECT	stu.relname,
		stu.n_live_tup,
		stu.n_dead_tup
FROM	pg_catalog.pg_stat_user_tables stu
WHERE	stu.relname = 'table_to_delete';
-- Result right after the DELETE: n_live_tup 6 666 879, n_dead_tup 3 333 485 (statistics are estimates).
-- In a second run, checked about 20 s after the DELETE, n_dead_tup was only 44 354:
-- autovacuum had already processed the table in the background, yet the size stayed 575 MB.
 
-- 3c) Rewrite the table
VACUUM FULL VERBOSE public.table_to_delete;
-- Server output: found 5817 removable row versions (1631 in the second run). Only a few thousand,
-- because autovacuum had already cleaned the 3.3 million dead rows before VACUUM FULL started.
-- Execution time about 10 s
 
-- 3d) Space after VACUUM FULL: run the Step 2 query again
-- Result: total 383 MB (401 580 032 bytes: table 401 571 840 + toast 8 192), about 1/3 smaller
-- Conclusion: even after autovacuum the file was still 575 MB. The space of deleted rows is
-- returned to the operating system only when the table is rewritten by VACUUM FULL.
 
-- 3e) Recreate table_to_delete
DROP TABLE IF EXISTS public.table_to_delete;
 
CREATE TABLE public.table_to_delete AS
SELECT	'veeeeeeery_long_string' || gen.x	AS col
FROM	generate_series(1, (10^7)::int) AS gen (x);
-- Space after recreation (Step 2 query): total 575 MB again
 
 
/*
	Step 4. TRUNCATE
*/
TRUNCATE public.table_to_delete;
-- 4a) Execution time about 0.055 s (all 10 000 000 rows)
-- 4b) DELETE of 1/3 of the rows took about 18 s, so TRUNCATE was about 330 times faster
--	   while removing 3 times more rows.
-- 4c) Space after TRUNCATE (Step 2 query): total 8192 bytes, table 0 bytes.
--	   The 8192 bytes are the empty TOAST structure; the data files are gone immediately,
--	   no VACUUM is needed.
 
 
/* ---------------------------------------------------------------------------------
	Step 5. Results for the mentor
 
	a) Space consumption of table_to_delete
 
		Moment							Total size   Bytes		

		After CREATE (10 000 000 rows)	575 MB	    602 415 104 
		After DELETE of 1/3 rows	    575 MB	    602 537 984 
		After VACUUM FULL				383 MB	    401 580 032
		After recreate					575 MB	    602 415 104
		After TRUNCATE					8192 bytes  8192
 
	b)
		Execution time
			DELETE: about 18 s for 3 333 333 rows. It scans every row, evaluates the WHERE
			condition and marks each matching row as deleted one by one, writing WAL for
			every row.
			
			TRUNCATE: about 0.055 s for 10 000 000 rows. It does not touch rows; it replaces
			the table's data files with new empty ones, so the time hardly depends on the
			table size.
 
		Disk space usage
			DELETE: the table keeps its size (575 MB, even +120 KB for the free space and
			visibility maps). Space is freed only by VACUUM
			(reused inside the table) or VACUUM FULL (returned to the OS, 383 MB here).
			
			TRUNCATE: space is returned to the OS right away (8 KB left).
 
		Transaction behavior
			DELETE: row-level DML. Takes a ROW EXCLUSIVE lock, so other sessions can still
			read and even change other rows. Can have WHERE, fires row-level DELETE
			triggers, supports RETURNING.
			
			TRUNCATE: takes an ACCESS EXCLUSIVE lock, which blocks every read and write on
			the table until the transaction ends. No WHERE (all rows only), no row-level
			triggers (only statement-level TRUNCATE triggers), fails on a table referenced
			by a foreign key unless CASCADE is used. With RESTART IDENTITY it
			also resets the sequences owned by the table.
 
		Rollback possibility
			In PostgreSQL both can be rolled back if they run inside an explicit transaction
			(BEGIN ... ROLLBACK). With autocommit ON, as in this task, each statement is
			committed at once, so neither can be undone afterwards.
			
			Difference: after a committed DELETE the dead rows stay in the file until vacuum,
			but they are still not visible and cannot be restored with SQL. TRUNCATE is not
			MVCC-safe: after it commits, transactions that started earlier see the table
			as empty.
 
	c) Explanations
 
		Why DELETE does not free space immediately
			PostgreSQL uses MVCC. DELETE does not remove a row physically; it marks the row
			version as deleted (sets xmax). Other transactions that started earlier may
			still need to see it, and the deleting transaction may roll back. So the row
			stays in the page as a dead tuple until VACUUM confirms nobody needs it.
 
		Why VACUUM FULL changes table size
			Plain VACUUM only marks dead tuples' space as reusable for future inserts in the
			same table; the file size stays the same. VACUUM FULL writes a brand-new copy of
			the table with only live rows, then drops the old
			file. The new file is smaller (575 MB -> 383 MB), so the space goes back to the
			OS. It needs an ACCESS EXCLUSIVE lock and temporary extra disk space for the copy.
 
		Why TRUNCATE behaves differently
			TRUNCATE is a DDL-like operation on the whole table: it creates a new empty data
			file and drops the old one at commit, instead of processing rows. No dead
			tuples are created, nothing has to be vacuumed, and only a small amount of WAL
			is written.
 
		How these operations affect performance and storage
			- Mass DELETE is slow, writes a lot of WAL and leaves table bloat: scans still
			  read the dead rows and the table stays large until vacuumed.
			- Autovacuum/VACUUM makes the space reusable without locking readers, but does
			  not shrink the file. This was visible in my run: autovacuum removed almost all
			  dead rows (VACUUM FULL then found only 5 817), but the table was still 575 MB.
			- VACUUM FULL shrinks the file but blocks the table for the whole rewrite, so it
			  should be run in a maintenance window.
			- TRUNCATE is the fastest way to empty a table and frees space at once, but it
			  blocks all access while it runs and cannot remove only part of the rows.
			- Practical rule: to remove all rows, use TRUNCATE; to remove some rows, use
			  DELETE and let autovacuum (or a planned VACUUM FULL after a very large delete)
			  clean up.
*/
 