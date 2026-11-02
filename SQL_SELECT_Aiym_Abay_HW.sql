/*DATABASE SCHEMA ANALYSIS
	------------------------
	Transactional (fact) tables - grow with every business event:
		public.rental - each rental of a film copy (rental_date, return_date)
		public.payment - each payment for a rental (amount, payment_date)
 
	Reference (dimension / lookup) tables - describe entities, change rarely:
		public.film, public.actor, public.category, public.language,
		public.customer, public.staff, public.store, public.inventory,
		public.address, public.city, public.country
 
	Bridge (connecting, many-to-many) tables:
		public.film_actor - film <-> actor
		public.film_category - film <-> category
 
	Key relationship paths used below:
		payment -> rental -> inventory -> film      (what was paid for)
		payment -> rental -> inventory -> store     (where it was rented)
		payment -> staff                            (who processed the payment)
		film -> film_actor -> actor
		film -> film_category -> category
 
	GENERAL ASSUMPTIONS
	----------------------------------------
	1. Category names are compared in upper case (UPPER(...)) so the filter
	   still works if a name is stored as 'drama' or 'DRAMA'.
	2. Date ranges are written as  >= start AND < next_start  instead of
	   EXTRACT(YEAR ...) so that an index on the date column can be used.
	3. "Top-N" results keep ties: FETCH FIRST N ROWS WITH TIES returns every
	   row that has the same value as the N-th row, so nobody with an equal
	   result is cut off arbitrarily. This is a standard SQL clause (not a
	   window function) and needs PostgreSQL 13 or newer. WITH TIES compares
	   ALL ORDER BY columns, so in these queries ORDER BY contains only the
	   measure (count / revenue / gap) - no extra name sorting.
	4. No window functions are used anywhere.
 
	JOIN TYPES USED
	---------------
	INNER JOIN - keeps only rows that have a match on both sides. Used when a
	             row without a match is not wanted in the result (e.g. a film
	             without the 'Animation' category).
	LEFT JOIN  - keeps every row of the left table; columns of the right table
	             become NULL when there is no match. Used when an entity must
	             appear even without related data (e.g. a store without
	             payments, a year without Drama films) - the NULLs are then
	             replaced by 0 with COALESCE.
*/

/* 
	PART 1 
*/
/* ----------------------------------------------------------------------------
	TASK 1.1
	The marketing team needs a list of animation movies between 2017 and 2019
	to promote family-friendly content in an upcoming season in stores.
	Show all animation movies released during this period with rate more
	than 1, sorted alphabetically.
		
		assumptions:
	- "between 2017 and 2019" is inclusive: release_year 2017, 2018, 2019.
	- "rate" is film.rental_rate (price of one rental), condition > 1.
	- "animation movie" = film linked to the category named 'Animation'.
	- Sorted alphabetically by title

---------------------------------------------------------------------------- */
 
-- 1.1 JOIN solution
--only films that have the 'Animation' category stay in the result.
SELECT	flm.title,
		flm.release_year,
		flm.rental_rate
FROM	public.film				flm
INNER JOIN public.film_category	flmcat	ON flm.film_id			= flmcat.film_id
INNER JOIN public.category		cat		ON flmcat.category_id	= cat.category_id
WHERE	UPPER(cat.name)		= 'ANIMATION'	AND
		flm.release_year	BETWEEN 2017 AND 2019	AND
		flm.rental_rate		> 1
ORDER BY flm.title;
 
-- 1.1 SUBQUERY solution
--subquery returns the ids of all animation films; 
--the outer query keeps films whose id is in that list. 
--Its INNER JOIN drops film_category rows whose category is not 'Animation'.
SELECT	flm.title,
		flm.release_year,
		flm.rental_rate
FROM	public.film flm
WHERE	flm.film_id IN (
			SELECT	flmcat.film_id
			FROM	public.film_category	flmcat
			INNER JOIN public.category	cat		ON flmcat.category_id = cat.category_id
			WHERE	UPPER(cat.name) = 'ANIMATION'
		)									AND
		flm.release_year	BETWEEN 2017 AND 2019	AND
		flm.rental_rate		> 1
ORDER BY flm.title;
 
-- 1.1 CTE solution
--prepares the list of animation film ids; INNER JOIN with it keeps only animation films.
WITH animation_films AS (
	SELECT	flmcat.film_id
	FROM	public.film_category	flmcat
	INNER JOIN public.category	cat		ON flmcat.category_id = cat.category_id
	WHERE	UPPER(cat.name) = 'ANIMATION'
)
SELECT	flm.title,
		flm.release_year,
		flm.rental_rate
FROM	public.film			flm
INNER JOIN animation_films	anf		ON flm.film_id = anf.film_id
WHERE	flm.release_year	BETWEEN 2017 AND 2019	AND
		flm.rental_rate		> 1
ORDER BY flm.title;
 
/*
	1.1 Comparison
	- JOIN:shortest and easiest to read; the optimizer handles it best.
	            Risk: if a film had the same category twice it would be
	            duplicated (impossible here - PK of film_category is
	            (film_id, category_id)).
	- SUBQUERY: IN (...) can never duplicate films, and it clearly separates
	            "which films are animation" from "which of them match the
	            filters". Slightly harder to read when nested.
	- CTE:most readable - the animation list has a name and can be
	            tested on its own.
	Production choice: JOIN - the task is a simple filter over three tables,
	so extra structure does not add clarity.
*/ 
/* ----------------------------------------------------------------------------
	TASK 1.2
	The finance department requires a report on store performance to assess
	profitability and plan resource allocation for stores after March 2017.
	Calculate the revenue earned by each rental store after March 2017
	(since April) (include columns: address and address2 - as one column,
	revenue).
 
	assumptions:
	- Revenue = SUM(payment.amount) of payments with payment_date on or after
	  2017-04-01 (no upper limit - everything after March).
	- A payment belongs to the store that owns the rented copy:
	  payment -> rental -> inventory -> store.
	- address and address2 are concatenated with ', '. address2 is often NULL
	  or an empty string; CONCAT_WS skips NULLs and NULLIF turns '' into NULL,
	  so there is no trailing comma.
	- Every store is shown, even one with no payments since April
	  (revenue = 0), because finance needs the whole picture.
---------------------------------------------------------------------------- */
 
-- 1.2 JOIN solution
-- store INNER JOIN address: every store has an address.
-- LEFT JOINs to inventory/rental/payment: a store stays in the result even if
-- it has no rentals or payments (its payment columns are NULL).
-- The date filter is in the CASE (not in WHERE): a WHERE filter on payment
-- would remove stores without April+ payments and turn the LEFT JOINs into
-- INNER JOINs.
SELECT	CONCAT_WS(', ', adr.address, NULLIF(TRIM(adr.address2), ''))	AS store_address,
		SUM(CASE
				WHEN pmt.payment_date >= DATE '2017-04-01' THEN pmt.amount
				ELSE 0
			END)													AS revenue
FROM	public.store			str
INNER JOIN public.address	adr		ON str.address_id		= adr.address_id
LEFT JOIN public.inventory	inv		ON str.store_id			= inv.store_id
LEFT JOIN public.rental		rnt		ON inv.inventory_id		= rnt.inventory_id
LEFT JOIN public.payment	pmt		ON rnt.rental_id		= pmt.rental_id
GROUP BY str.store_id,
		adr.address,
		adr.address2
ORDER BY revenue DESC;
 
-- 1.2 SUBQUERY solution
-- The derived table calculates revenue per store id (INNER JOINs: only
-- payments that can be traced to a store copy).
-- LEFT JOIN from store keeps stores that do not appear in the derived table;
-- COALESCE turns their NULL revenue into 0.
SELECT	CONCAT_WS(', ', adr.address, NULLIF(TRIM(adr.address2), ''))	AS store_address,
		COALESCE(strrev.revenue, 0)										AS revenue
FROM	public.store			str
INNER JOIN public.address	adr		ON str.address_id = adr.address_id
LEFT JOIN (
			SELECT	inv.store_id,
					SUM(pmt.amount)	AS revenue
			FROM	public.payment			pmt
			INNER JOIN public.rental		rnt		ON pmt.rental_id	= rnt.rental_id
			INNER JOIN public.inventory	inv		ON rnt.inventory_id	= inv.inventory_id
			WHERE	pmt.payment_date >= DATE '2017-04-01'
			GROUP BY inv.store_id
		) strrev						ON str.store_id = strrev.store_id
ORDER BY revenue DESC;
 
-- 1.2 CTE solution
-- Same logic as the subquery, but the revenue calculation is a named step.
WITH store_revenue AS (
	SELECT	inv.store_id,
			SUM(pmt.amount)	AS revenue
	FROM	public.payment			pmt
	INNER JOIN public.rental		rnt		ON pmt.rental_id	= rnt.rental_id
	INNER JOIN public.inventory	inv		ON rnt.inventory_id	= inv.inventory_id
	WHERE	pmt.payment_date >= DATE '2017-04-01'
	GROUP BY inv.store_id
)
SELECT	CONCAT_WS(', ', adr.address, NULLIF(TRIM(adr.address2), ''))	AS store_address,
		COALESCE(strrev.revenue, 0)										AS revenue
FROM	public.store			str
INNER JOIN public.address	adr		ON str.address_id	= adr.address_id
LEFT JOIN store_revenue		strrev	ON str.store_id		= strrev.store_id
ORDER BY revenue DESC;

/*
	1.2 Comparison
	- JOIN:one flat query, but it reads ALL payments (the date filter is
	            inside the CASE, so no index on payment_date can be used) and
	            joins all inventory/rental rows before grouping - the most
	            expensive version on a large table.
	- SUBQUERY: filters payments by date first (index can be used), groups
	            them, and only then joins the tiny result (one row per store)
	            to store/address. Efficient, but the nested block makes the
	            query harder to read.
	- CTE:same efficiency as the subquery; the revenue step has a name
	            and reads top-to-bottom.
	Production choice: CTE - filtering before joining is cheaper, and the
	named step is easy to read, test and change.
*/
 
 
/* ----------------------------------------------------------------------------
	TASK 1.3
	The marketing department in our stores aims to identify the most
	successful actors since 2015 to boost customer interest in their films.
	Show top-5 actors by number of movies (released since 2015) they took
	part in (columns: first_name, last_name, number_of_movies, sorted by
	number_of_movies in descending order).
 
	assumptions:
	- "since 2015" includes 2015: release_year >= 2015.
	- Actors are grouped by actor_id (two different actors can have the same
	  name), but actor_id is not shown, per the required columns.
	- Ties: WITH TIES returns every actor with as many films as the 5th one,
	  so the result can have more than 5 rows.
	- ORDER BY contains only number_of_movies: WITH TIES compares ALL
	  ORDER BY columns, so an extra sort by name would break the ties and
	  cut tied actors off.
---------------------------------------------------------------------------- */
 
-- 1.3 JOIN solution
-- INNER JOINs: only actors that have at least one film released since 2015.
SELECT	act.first_name,
		act.last_name,
		COUNT(flmact.film_id)	AS number_of_movies
FROM	public.actor				act
INNER JOIN public.film_actor	flmact	ON act.actor_id		= flmact.actor_id
INNER JOIN public.film			flm		ON flmact.film_id	= flm.film_id
WHERE	flm.release_year >= 2015
GROUP BY act.actor_id,
		act.first_name,
		act.last_name
ORDER BY number_of_movies DESC
FETCH FIRST 5 ROWS WITH TIES;
 
-- 1.3 SUBQUERY solution
-- The derived table counts films per actor_id; INNER JOIN with actor adds
-- the names (all actor_ids in the derived table exist in actor).
SELECT	act.first_name,
		act.last_name,
		actcnt.number_of_movies
FROM	public.actor act
INNER JOIN (
			SELECT	flmact.actor_id,
					COUNT(flmact.film_id)	AS number_of_movies
			FROM	public.film_actor	flmact
			INNER JOIN public.film	flm		ON flmact.film_id = flm.film_id
			WHERE	flm.release_year >= 2015
			GROUP BY flmact.actor_id
		) actcnt					ON act.actor_id = actcnt.actor_id
ORDER BY actcnt.number_of_movies DESC
FETCH FIRST 5 ROWS WITH TIES;
 
-- 1.3 CTE solution
WITH actor_movie_count AS (
	SELECT	flmact.actor_id,
			COUNT(flmact.film_id)	AS number_of_movies
	FROM	public.film_actor	flmact
	INNER JOIN public.film	flm		ON flmact.film_id = flm.film_id
	WHERE	flm.release_year >= 2015
	GROUP BY flmact.actor_id
)
SELECT	act.first_name,
		act.last_name,
		amc.number_of_movies
FROM	public.actor			act
INNER JOIN actor_movie_count	amc		ON act.actor_id = amc.actor_id
ORDER BY amc.number_of_movies DESC
FETCH FIRST 5 ROWS WITH TIES;
 
/*
	1.3 Comparison
	- JOIN:compact; but GROUP BY has to list the name columns too, and
	            names are carried through the whole aggregation.
	- SUBQUERY: counts on narrow film_actor rows (ids only) and joins names
	            afterwards - slightly less data to group; nested and harder
	            to read.
	- CTE:same plan as the subquery, readable top-to-bottom; the count
	            step can be reused (e.g. for another report).
	Production choice: CTE - clear separation of "count" and "present",
	same performance as the subquery.
*/
 
 
/* ----------------------------------------------------------------------------
	TASK 1.4
	The marketing team needs to track the production trends of Drama, Travel,
	and Documentary films to inform genre-specific marketing strategies.
	Show number of Drama, Travel, Documentary per year (include columns:
	release_year, number_of_drama_movies, number_of_travel_movies,
	number_of_documentary_movies), sorted by release year in descending
	order. Dealing with NULL values is encouraged.
 
	assumptions:
	- Every release year that exists in public.film is shown, even if no
	  Drama/Travel/Documentary film was released that year - a trend report
	  needs to show the "0" years, not skip them.
	- NULL handling: missing counts are shown as 0 (COALESCE), never as NULL.
	  Films with NULL release_year are excluded - they cannot be placed on a
	  timeline.
	- A film is counted once per genre (COUNT(DISTINCT film_id)).
---------------------------------------------------------------------------- */
 
-- 1.4 JOIN solution
-- LEFT JOINs: every film (and so every year) stays, even films without a
-- category. Conditional aggregation counts each genre in its own column.
-- COUNT ignores NULLs and returns 0 (not NULL) when nothing matched.
SELECT	flm.release_year,
		COUNT(DISTINCT CASE WHEN UPPER(cat.name) = 'DRAMA'			THEN flm.film_id END)	AS number_of_drama_movies,
		COUNT(DISTINCT CASE WHEN UPPER(cat.name) = 'TRAVEL'			THEN flm.film_id END)	AS number_of_travel_movies,
		COUNT(DISTINCT CASE WHEN UPPER(cat.name) = 'DOCUMENTARY'	THEN flm.film_id END)	AS number_of_documentary_movies
FROM	public.film					flm
LEFT JOIN public.film_category	flmcat	ON flm.film_id			= flmcat.film_id
LEFT JOIN public.category		cat		ON flmcat.category_id	= cat.category_id
WHERE	flm.release_year IS NOT NULL
GROUP BY flm.release_year
ORDER BY flm.release_year DESC;
 
-- 1.4 SUBQUERY solution
-- Outer query: list of distinct years. Each column is a correlated scalar
-- subquery counting films of one genre in that year (INNER JOINs inside:
-- only films that have the genre). COUNT returns 0 for years with no films
-- of that genre; COALESCE is kept as protection in case the subquery is
-- changed to SUM or another function that returns NULL on empty input.
SELECT	yrs.release_year,
		COALESCE((
			SELECT	COUNT(DISTINCT flm.film_id)
			FROM	public.film					flm
			INNER JOIN public.film_category	flmcat	ON flm.film_id			= flmcat.film_id
			INNER JOIN public.category		cat		ON flmcat.category_id	= cat.category_id
			WHERE	UPPER(cat.name)		= 'DRAMA'	AND
					flm.release_year	= yrs.release_year
		), 0)											AS number_of_drama_movies,
		COALESCE((
			SELECT	COUNT(DISTINCT flm.film_id)
			FROM	public.film					flm
			INNER JOIN public.film_category	flmcat	ON flm.film_id			= flmcat.film_id
			INNER JOIN public.category		cat		ON flmcat.category_id	= cat.category_id
			WHERE	UPPER(cat.name)		= 'TRAVEL'	AND
					flm.release_year	= yrs.release_year
		), 0)											AS number_of_travel_movies,
		COALESCE((
			SELECT	COUNT(DISTINCT flm.film_id)
			FROM	public.film					flm
			INNER JOIN public.film_category	flmcat	ON flm.film_id			= flmcat.film_id
			INNER JOIN public.category		cat		ON flmcat.category_id	= cat.category_id
			WHERE	UPPER(cat.name)		= 'DOCUMENTARY'	AND
					flm.release_year	= yrs.release_year
		), 0)											AS number_of_documentary_movies
FROM	(
			SELECT	DISTINCT flm.release_year
			FROM	public.film flm
			WHERE	flm.release_year IS NOT NULL
		) yrs
ORDER BY yrs.release_year DESC;
 
-- 1.4 CTE solution
-- genre_counts holds counts only for years where the three genres exist.
-- LEFT JOIN from the list of all years keeps years missing in genre_counts;
-- their counts are NULL and COALESCE replaces them with 0.
WITH release_years AS (
	SELECT	DISTINCT flm.release_year
	FROM	public.film flm
	WHERE	flm.release_year IS NOT NULL
),
genre_counts AS (
	SELECT	flm.release_year,
			COUNT(DISTINCT CASE WHEN UPPER(cat.name) = 'DRAMA'			THEN flm.film_id END)	AS drama_count,
			COUNT(DISTINCT CASE WHEN UPPER(cat.name) = 'TRAVEL'			THEN flm.film_id END)	AS travel_count,
			COUNT(DISTINCT CASE WHEN UPPER(cat.name) = 'DOCUMENTARY'	THEN flm.film_id END)	AS documentary_count
	FROM	public.film					flm
	INNER JOIN public.film_category	flmcat	ON flm.film_id			= flmcat.film_id
	INNER JOIN public.category		cat		ON flmcat.category_id	= cat.category_id
	WHERE	UPPER(cat.name) IN ('DRAMA', 'TRAVEL', 'DOCUMENTARY')
	GROUP BY flm.release_year
)
SELECT	rly.release_year,
		COALESCE(gnc.drama_count, 0)		AS number_of_drama_movies,
		COALESCE(gnc.travel_count, 0)		AS number_of_travel_movies,
		COALESCE(gnc.documentary_count, 0)	AS number_of_documentary_movies
FROM	release_years		rly
LEFT JOIN genre_counts	gnc		ON rly.release_year = gnc.release_year
ORDER BY rly.release_year DESC;

/*
	1.4 Comparison
	- JOIN: one pass over film/film_category/category with conditional
	            aggregation - efficient and short. Needs care: a WHERE filter
	            on cat.name would remove years without these genres.
	- SUBQUERY: easy to understand column by column, but each correlated
	            subquery runs once per year (3 x number of years executions)
	            and the code is repeated three times - slowest and hardest to
	            maintain.
	- CTE: filters to the 3 genres first (less data to aggregate) and
	            makes the "all years" list explicit; the LEFT JOIN + COALESCE
	            shows NULL handling clearly. A bit longer.
	Production choice: CTE - explicit year list, early filtering, and clear
	NULL handling; the JOIN version is a good alternative.
*/
 
 
/* 
	PART 2
*/
 
/* ----------------------------------------------------------------------------
	TASK 2.1
	The HR department aims to reward top-performing employees in 2017 with
	bonuses to recognize their contribution to stores revenue. Show which
	three employees generated the most revenue in 2017?
 
	assumptions (given):
	- staff could work in several stores in a year, please indicate which
	  store the staff worked in (the last one);
	- if staff processed the payment then he works in the same store;
	- take into account only payment_date.
 
	interpretation:
	- Revenue of an employee = SUM(payment.amount) of payments with
	  payment.staff_id = employee and payment_date in 2017
	  (>= 2017-01-01 AND < 2018-01-01).
	- Store of a payment = store that owns the rented copy
	  (payment -> rental -> inventory -> store). Because the staff member
	  processed that payment, he/she worked in that store at that moment.
	- "Last store" = store of the employee's latest payment in 2017.
	  staff.store_id is NOT used - it only holds the current assignment.
	- If two payments share the exact latest timestamp but belong to
	  different stores, the higher store_id is taken (MAX) so there is
	  exactly one row per employee.
	- Ties for 3rd place are kept (WITH TIES).
---------------------------------------------------------------------------- */
 
-- 2.1 CTE solution
-- staff_revenue: revenue per employee in 2017.
-- last_payment: time of each employee's latest 2017 payment.
-- last_store: store of that latest payment. INNER JOIN with last_payment keeps only the payments made at the latest time.
-- Final INNER JOINs: only employees that have 2017 revenue are shown.
WITH staff_revenue AS (
	SELECT	pmt.staff_id,
			SUM(pmt.amount)	AS revenue
	FROM	public.payment pmt
	WHERE	pmt.payment_date >= DATE '2017-01-01'	AND
			pmt.payment_date <  DATE '2018-01-01'
	GROUP BY pmt.staff_id
),
last_payment AS (
	SELECT	pmt.staff_id,
			MAX(pmt.payment_date)	AS last_payment_date
	FROM	public.payment pmt
	WHERE	pmt.payment_date >= DATE '2017-01-01'	AND
			pmt.payment_date <  DATE '2018-01-01'
	GROUP BY pmt.staff_id
),
last_store AS (
	SELECT	pmt.staff_id,
			MAX(inv.store_id)	AS store_id
	FROM	public.payment			pmt
	INNER JOIN last_payment		lpm		ON pmt.staff_id			= lpm.staff_id	AND
											pmt.payment_date	= lpm.last_payment_date
	INNER JOIN public.rental		rnt		ON pmt.rental_id		= rnt.rental_id
	INNER JOIN public.inventory	inv		ON rnt.inventory_id		= inv.inventory_id
	GROUP BY pmt.staff_id
)
SELECT	stf.first_name,
		stf.last_name,
		lst.store_id		AS last_store_id,
		srv.revenue
FROM	staff_revenue		srv
INNER JOIN public.staff	stf		ON srv.staff_id = stf.staff_id
INNER JOIN last_store	lst		ON srv.staff_id = lst.staff_id
ORDER BY srv.revenue DESC
FETCH FIRST 3 ROWS WITH TIES;
 
-- 2.1 SUBQUERY solution
-- Derived table srv: revenue per employee in 2017.
-- Correlated subquery in SELECT: store of the employee's latest 2017 payment;
-- the nested subquery finds that latest payment time.
SELECT	stf.first_name,
		stf.last_name,
		(
			SELECT	MAX(inv.store_id)
			FROM	public.payment			pmt
			INNER JOIN public.rental		rnt		ON pmt.rental_id	= rnt.rental_id
			INNER JOIN public.inventory	inv		ON rnt.inventory_id	= inv.inventory_id
			WHERE	pmt.staff_id		= stf.staff_id	AND
					pmt.payment_date	= (
						SELECT	MAX(pmt_last.payment_date)
						FROM	public.payment pmt_last
						WHERE	pmt_last.staff_id		=  stf.staff_id				AND
								pmt_last.payment_date	>= DATE '2017-01-01'		AND
								pmt_last.payment_date	<  DATE '2018-01-01'
					)
		)						AS last_store_id,
		srv.revenue
FROM	public.staff stf
INNER JOIN (
			SELECT	pmt.staff_id,
					SUM(pmt.amount)	AS revenue
			FROM	public.payment pmt
			WHERE	pmt.payment_date >= DATE '2017-01-01'	AND
					pmt.payment_date <  DATE '2018-01-01'
			GROUP BY pmt.staff_id
		) srv						ON stf.staff_id = srv.staff_id
ORDER BY srv.revenue DESC
FETCH FIRST 3 ROWS WITH TIES;
 
-- 2.1 JOIN solution
-- One grouped query, no subqueries. The "last store" is found with a string
-- trick: for every payment a text key  'YYYYMMDDHH24MISSUS|store_id'  is
-- built. The timestamp part has a fixed length, so text order = time order,
-- and MAX(key) is the key of the latest payment. SPLIT_PART takes the part
-- after '|' = store_id of that payment.
-- INNER JOINs: every payment has a rental and every rental has an inventory
-- row, so no 2017 payment is lost.
SELECT	stf.first_name,
		stf.last_name,
		SPLIT_PART(
			MAX(TO_CHAR(pmt.payment_date, 'YYYYMMDDHH24MISSUS') || '|' || inv.store_id::TEXT),
			'|', 2
		)::INTEGER				AS last_store_id,
		SUM(pmt.amount)			AS revenue
FROM	public.payment			pmt
INNER JOIN public.staff		stf		ON pmt.staff_id			= stf.staff_id
INNER JOIN public.rental		rnt		ON pmt.rental_id		= rnt.rental_id
INNER JOIN public.inventory	inv		ON rnt.inventory_id		= inv.inventory_id
WHERE	pmt.payment_date >= DATE '2017-01-01'	AND
		pmt.payment_date <  DATE '2018-01-01'
GROUP BY stf.staff_id,
		stf.first_name,
		stf.last_name
ORDER BY revenue DESC
FETCH FIRST 3 ROWS WITH TIES;
 
/*
	2.1 Comparison
	- CTE: each business rule (revenue, last payment, last store) is a
	            separate named step - easiest to read, explain and test.
	            Reads the payment table three times.
	- SUBQUERY: revenue in a derived table, last store in a correlated
	            subquery that runs once per employee (cheap here because there
	            are few employees, slow if there were thousands). Two levels
	            of nesting make it the hardest to read.
	- JOIN: a single pass over payments - the fastest. But the "last
	            store" logic depends on a string-building trick (fixed-length
	            date format + text MAX), which is not obvious to a reader and
	            would break if the format changed. Pure joins cannot express
	            "value from the row with the latest date" without either a
	            subquery, a window function (not allowed) or such a trick.
	Production choice: CTE - correctness and readability matter more than
	reading a small table three times; each step can be checked separately.
*/
 
 
/* ----------------------------------------------------------------------------
	TASK 2.2
	The management team wants to identify the most popular movies and their
	target audience age groups to optimize marketing efforts. Show which 5
	movies were rented more than others (number of rentals), and what's the
	expected age of the audience for these movies? To determine expected age
	please use 'Motion Picture Association film rating system'.
 
	assumptions:
	- Number of rentals of a film = number of rental rows for all its copies
	  (film -> inventory -> rental), all time.
	- Expected audience age by MPA rating:
	    G     - General Audiences: all ages admitted
	    PG    - Parental Guidance Suggested: all ages, some material may not
	            be suitable for children
	    PG-13 - Parents Strongly Cautioned: 13+
	    R     - Restricted: 17+ (under 17 only with a parent or adult guardian)
	    NC-17 - Adults Only: 18+ (no one 17 and under admitted)
	- Ties for 5th place are kept (WITH TIES). ORDER BY contains only
	  number_of_rentals - an extra sort column would break the ties.
---------------------------------------------------------------------------- */
 
-- 2.2 JOIN solution
-- INNER JOINs: only films that have been rented at least once (a film
-- without copies or rentals cannot be among the most rented).
SELECT	flm.title,
		flm.rating,
		CASE flm.rating::TEXT
			WHEN 'G'		THEN 'All ages'
			WHEN 'PG'		THEN 'All ages (parental guidance suggested)'
			WHEN 'PG-13'	THEN '13+'
			WHEN 'R'		THEN '17+ (under 17 with a parent or adult guardian)'
			WHEN 'NC-17'	THEN '18+'
			ELSE 'Not rated'
		END							AS expected_audience_age,
		COUNT(rnt.rental_id)		AS number_of_rentals
FROM	public.film				flm
INNER JOIN public.inventory	inv		ON flm.film_id		= inv.film_id
INNER JOIN public.rental		rnt		ON inv.inventory_id	= rnt.inventory_id
GROUP BY flm.film_id,
		flm.title,
		flm.rating
ORDER BY number_of_rentals DESC
FETCH FIRST 5 ROWS WITH TIES;
 
-- 2.2 SUBQUERY solution
-- Derived table counts rentals per film_id; INNER JOIN with film adds the
-- title and rating.
SELECT	flm.title,
		flm.rating,
		CASE flm.rating::TEXT
			WHEN 'G'		THEN 'All ages'
			WHEN 'PG'		THEN 'All ages (parental guidance suggested)'
			WHEN 'PG-13'	THEN '13+'
			WHEN 'R'		THEN '17+ (under 17 with a parent or adult guardian)'
			WHEN 'NC-17'	THEN '18+'
			ELSE 'Not rated'
		END							AS expected_audience_age,
		flmrnt.number_of_rentals
FROM	public.film flm
INNER JOIN (
			SELECT	inv.film_id,
					COUNT(rnt.rental_id)	AS number_of_rentals
			FROM	public.rental			rnt
			INNER JOIN public.inventory	inv		ON rnt.inventory_id = inv.inventory_id
			GROUP BY inv.film_id
		) flmrnt					ON flm.film_id = flmrnt.film_id
ORDER BY flmrnt.number_of_rentals DESC
FETCH FIRST 5 ROWS WITH TIES;
 
-- 2.2 CTE solution
WITH film_rentals AS (
	SELECT	inv.film_id,
			COUNT(rnt.rental_id)	AS number_of_rentals
	FROM	public.rental			rnt
	INNER JOIN public.inventory	inv		ON rnt.inventory_id = inv.inventory_id
	GROUP BY inv.film_id
)
SELECT	flm.title,
		flm.rating,
		CASE flm.rating::TEXT
			WHEN 'G'		THEN 'All ages'
			WHEN 'PG'		THEN 'All ages (parental guidance suggested)'
			WHEN 'PG-13'	THEN '13+'
			WHEN 'R'		THEN '17+ (under 17 with a parent or adult guardian)'
			WHEN 'NC-17'	THEN '18+'
			ELSE 'Not rated'
		END							AS expected_audience_age,
		frn.number_of_rentals
FROM	public.film			flm
INNER JOIN film_rentals	frn		ON flm.film_id = frn.film_id
ORDER BY frn.number_of_rentals DESC
FETCH FIRST 5 ROWS WITH TIES;
 
/*
	2.2 Comparison
	- JOIN: shortest; but text columns (title, rating) are carried
	            through the GROUP BY over all rental rows.
	- SUBQUERY: groups only ids (rental + inventory), then joins film -
	            less data to aggregate; nested block is less readable.
	- CTE: same efficiency as the subquery, clearest structure; the
	            "rentals per film" step is reusable.
	Production choice: CTE. (Even better in production: keep the rating ->
	age mapping in a small reference table instead of a CASE repeated in
	code, so it can be changed in one place.)
*/
 
 
/* 
	PART 3
	Which actors/actresses didn't act for a longer period of time than the
	others?
	The stores' marketing team wants to analyze actors' inactivity periods to
	select those with notable career breaks for targeted promotional
	campaigns, highlighting their comebacks or consistent appearances to
	engage customers with nostalgic or reliable film stars.
	V1: gap between the latest release_year and current year per each actor;
	V2: gaps between sequential films per each actor.
 
	General interpretation:
	- "Longer than the others" = the actor(s) with the maximum gap; all
	  actors sharing the maximum are returned (WITH TIES).
	- Only actors who have at least one film with a known release_year are
	  considered (INNER JOINs) - an actor without films has no career gap
	  to measure.
 */
 
/* ----------------------------------------------------------------------------
	TASK 3 - V1
	Gap between the actor's latest release_year and the current year.
	- Current year is taken from CURRENT_DATE, so the result
	  stays correct next year.
	- years_without_films = current year - latest release year.
---------------------------------------------------------------------------- */
 
-- 3 V1 JOIN solution
SELECT	act.first_name,
		act.last_name,
		MAX(flm.release_year)										AS latest_release_year,
		EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - MAX(flm.release_year)	AS years_without_films
FROM	public.actor				act
INNER JOIN public.film_actor	flmact	ON act.actor_id		= flmact.actor_id
INNER JOIN public.film			flm		ON flmact.film_id	= flm.film_id
WHERE	flm.release_year IS NOT NULL
GROUP BY act.actor_id,
		act.first_name,
		act.last_name
ORDER BY years_without_films DESC
FETCH FIRST 1 ROWS WITH TIES;
 
-- 3 V1 SUBQUERY solution
-- Derived table: latest release year per actor_id.
-- WHERE compares each actor's latest year with the minimum latest year of
-- all actors (= the longest gap), so ties are kept without FETCH.
SELECT	act.first_name,
		act.last_name,
		alr.latest_release_year,
		EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - alr.latest_release_year	AS years_without_films
FROM	public.actor act
INNER JOIN (
			SELECT	flmact.actor_id,
					MAX(flm.release_year)	AS latest_release_year
			FROM	public.film_actor	flmact
			INNER JOIN public.film	flm		ON flmact.film_id = flm.film_id
			WHERE	flm.release_year IS NOT NULL
			GROUP BY flmact.actor_id
		) alr						ON act.actor_id = alr.actor_id
WHERE	alr.latest_release_year = (
			SELECT	MIN(latest.latest_release_year)
			FROM	(
						SELECT	MAX(flm.release_year)	AS latest_release_year
						FROM	public.film_actor	flmact
						INNER JOIN public.film	flm		ON flmact.film_id = flm.film_id
						WHERE	flm.release_year IS NOT NULL
						GROUP BY flmact.actor_id
					) latest
		)
ORDER BY act.last_name,
		act.first_name;
 
-- 3 V1 CTE solution
WITH actor_latest_release AS (
	SELECT	flmact.actor_id,
			MAX(flm.release_year)	AS latest_release_year
	FROM	public.film_actor	flmact
	INNER JOIN public.film	flm		ON flmact.film_id = flm.film_id
	WHERE	flm.release_year IS NOT NULL
	GROUP BY flmact.actor_id
)
SELECT	act.first_name,
		act.last_name,
		alr.latest_release_year,
		EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - alr.latest_release_year	AS years_without_films
FROM	public.actor				act
INNER JOIN actor_latest_release	alr		ON act.actor_id = alr.actor_id
WHERE	alr.latest_release_year = (
			SELECT	MIN(alr_all.latest_release_year)
			FROM	actor_latest_release alr_all
		)
ORDER BY act.last_name,
		act.first_name;
 
/*
	3 V1 Comparison
	- JOIN: shortest; ties handled by FETCH ... WITH TIES. Names are
	            carried through the GROUP BY.
	- SUBQUERY: has to repeat the "latest year per actor" aggregation twice
	            (once for the rows, once for the maximum gap) - duplicated
	            code and work.
	- CTE: the aggregation is written once and reused for both the rows
	            and the maximum gap - no duplication, very readable.
	Production choice: CTE - single definition of the rule, reused; no
	dependency on FETCH ... WITH TIES.
*/
 
 
/* ----------------------------------------------------------------------------
	TASK 3 - V2
	Gaps between sequential films per each actor.
 
	assumptions:
	- For each actor the distinct release years are taken (several films in
	  one year count as one working year).
	- For every year Y the "next film year" is the smallest release year of
	  the same actor that is greater than Y. Gap = next year - Y.
	  (Without window functions, LEAD() is replaced by MIN() over later
	  years.)
	- The last year of an actor has no next film and therefore no gap here
	  (that case is covered by V1). Actors with films in only one year have
	  no sequential gap and are not in the result.
	- Result: the longest gap(s) among all actors, with the years where the
	  break started and ended. If one actor has two equally long longest
	  gaps, both are shown.
---------------------------------------------------------------------------- */
 
-- 3 V2 JOIN solution
-- film_actor/film are joined twice: once for the "current" film (flm) and
-- once for any later film of the SAME actor (flm_next). INNER JOINs: a year
-- without a later film produces no row (that is the actor's last year).
-- The "later year" condition is in WHERE, joins use FK columns only.
-- MIN(flm_next.release_year) per (actor, year) = next film year.
SELECT	act.first_name,
		act.last_name,
		flm.release_year							AS gap_start_year,
		MIN(flm_next.release_year)					AS gap_end_year,
		MIN(flm_next.release_year) - flm.release_year	AS gap_years
FROM	public.actor				act
INNER JOIN public.film_actor	flmact		ON act.actor_id			= flmact.actor_id
INNER JOIN public.film			flm			ON flmact.film_id		= flm.film_id
INNER JOIN public.film_actor	flmact_next	ON act.actor_id			= flmact_next.actor_id
INNER JOIN public.film			flm_next	ON flmact_next.film_id	= flm_next.film_id
WHERE	flm_next.release_year > flm.release_year
GROUP BY act.actor_id,
		act.first_name,
		act.last_name,
		flm.release_year
ORDER BY gap_years DESC
FETCH FIRST 1 ROWS WITH TIES;
 
-- 3 V2 SUBQUERY solution
-- ayr: distinct (actor, release year) pairs.
-- The correlated subquery finds the next release year of the same actor.
-- The outer query keeps years that have a next year and returns the gap equal to the maximum gap.
SELECT	act.first_name,
		act.last_name,
		gps.gap_start_year,
		gps.gap_end_year,
		gps.gap_end_year - gps.gap_start_year	AS gap_years
FROM	public.actor act
INNER JOIN (
			SELECT	ayr.actor_id,
					ayr.release_year		AS gap_start_year,
					(
						SELECT	MIN(flm_next.release_year)
						FROM	public.film_actor	flmact_next
						INNER JOIN public.film	flm_next	ON flmact_next.film_id = flm_next.film_id
						WHERE	flmact_next.actor_id	= ayr.actor_id	AND
								flm_next.release_year	> ayr.release_year
					)						AS gap_end_year
			FROM	(
						SELECT	DISTINCT flmact.actor_id,
								flm.release_year
						FROM	public.film_actor	flmact
						INNER JOIN public.film	flm		ON flmact.film_id = flm.film_id
						WHERE	flm.release_year IS NOT NULL
					) ayr
		) gps						ON act.actor_id = gps.actor_id
WHERE	gps.gap_end_year IS NOT NULL
ORDER BY gap_years DESC
FETCH FIRST 1 ROWS WITH TIES;
 
-- 3 V2 CTE solution
-- actor_years: distinct (actor, release year) pairs.
-- actor_gaps: self-join of actor_years on actor_id; for each year the smallest later year (INNER JOIN: last years drop out).
-- max_gap: the longest gap of all actors.
WITH actor_years AS (
	SELECT	DISTINCT flmact.actor_id,
			flm.release_year
	FROM	public.film_actor	flmact
	INNER JOIN public.film	flm		ON flmact.film_id = flm.film_id
	WHERE	flm.release_year IS NOT NULL
),
actor_gaps AS (
	SELECT	ayr.actor_id,
			ayr.release_year				AS gap_start_year,
			MIN(ayr_next.release_year)		AS gap_end_year
	FROM	actor_years			ayr
	INNER JOIN actor_years	ayr_next	ON ayr.actor_id = ayr_next.actor_id
	WHERE	ayr_next.release_year > ayr.release_year
	GROUP BY ayr.actor_id,
			ayr.release_year
),
max_gap AS (
	SELECT	MAX(agp.gap_end_year - agp.gap_start_year)	AS max_gap_years
	FROM	actor_gaps agp
)
SELECT	act.first_name,
		act.last_name,
		agp.gap_start_year,
		agp.gap_end_year,
		agp.gap_end_year - agp.gap_start_year	AS gap_years
FROM	actor_gaps			agp
INNER JOIN public.actor	act		ON agp.actor_id = act.actor_id
CROSS JOIN max_gap		mgp		-- one-row CTE: CROSS JOIN adds max_gap_years to every row
WHERE	agp.gap_end_year - agp.gap_start_year = mgp.max_gap_years
ORDER BY act.last_name,
		act.first_name;
 
/*
	3 V2 Comparison
	- JOIN:no helper steps, but joins every film of an actor with every
	            later film of the same actor - for an actor with N films that
	            is up to N*N rows before grouping. Fine for this database,
	            expensive for large data. Duplicate years are absorbed by
	            GROUP BY / MIN, which is not obvious to a reader.
	- SUBQUERY: works on distinct years (less data), but the correlated
	            subquery runs once per (actor, year) row and goes back to the
	            base tables each time; two levels of nesting.
	- CTE: de-duplicates years once, then self-joins the small
	            actor_years set; every step (years -> gaps -> max gap) is
	            named and can be checked on its own; no FETCH needed.
	Production choice: CTE - smallest intermediate data and the clearest
	logic. In a real project (where window functions are allowed) LEAD()
	would replace the self-join and be faster still.
*/