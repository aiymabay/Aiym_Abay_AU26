/*
	The script is rerunnable:
		- every object is created with CREATE OR REPLACE (or IF NOT EXISTS);
		- DML inside the script is guarded with WHERE NOT EXISTS;
		- negative tests are wrapped in DO blocks that catch the expected
		  exception and print it with RAISE NOTICE, so the script never stops;
		- the "current quarter" test data is inserted inside a DO block that
		  rolls itself back, so nothing is left behind (also in Auto-commit mode).
	In DBeaver run it with Alt+X. Every test SELECT has a "-- title:" comment,
	so its result tab is named after the test; DO-block tests print their
	results in the Output panel (RAISE NOTICE).
	No IDs are hardcoded - every ID is looked up by a business key
	(name, title) or by a subquery.

	All new objects live in schema "core" (the task examples call
	core.most_popular_films_by_countries and core.films_in_stock_by_title);
	source tables are referenced with the explicit schema "public".
*/

CREATE SCHEMA IF NOT EXISTS core;

SELECT COUNT(*) AS rewardees FROM public.rewards_report(7, 20.00);

SELECT public.get_customer_balance(ren.customer_id, NOW()) AS balance
FROM public.rental ren
WHERE ren.return_date IS NULL
LIMIT 3;

SELECT COUNT(*) AS balance_functions
FROM pg_proc
WHERE proname = 'get_customer_balance';



SELECT 'old code still installed' AS check_name,
       (p.prosrc LIKE '%tmpSQL%')::TEXT AS result
FROM pg_proc p
WHERE p.proname = 'rewards_report'
UNION ALL
SELECT 'payments in ' || TO_CHAR(DATE_TRUNC('month', pay.payment_date), 'YYYY-MM'),
       COUNT(*)::TEXT
FROM public.payment pay
GROUP BY DATE_TRUNC('month', pay.payment_date)
ORDER BY check_name;

SELECT COUNT(*) AS rewardees FROM public.rewards_report(7, 20.00);

SELECT 'old code still installed' AS check_name,
       (p.prosrc LIKE '%tmpSQL%')::TEXT AS result
FROM pg_proc p
WHERE p.proname = 'rewards_report'
UNION ALL
SELECT 'customers passing in June 2017',
       COUNT(*)::TEXT
FROM (
	SELECT	pay.customer_id
	FROM	public.payment pay
	WHERE	pay.payment_date >= '2017-06-01' AND
			pay.payment_date <  '2017-07-01'
	GROUP BY pay.customer_id
	HAVING	SUM(pay.amount) > 20.00 AND
			COUNT(pay.payment_id) > 7
) june_customers;
/*
	TASK 1.

	What it returns: one row per film category with the total revenue
	(SUM(payment.amount)) collected in the current quarter of the current year.

	Join path (all joins by FK columns):
		payment -> rental -> inventory -> film_category -> category
	Revenue is taken from payment.amount (real money received), not from
	film.rental_rate (list price), because the task asks for sales revenue.

	How the CURRENT QUARTER and CURRENT YEAR are determined:
		DATE_TRUNC('quarter', CURRENT_DATE) returns the first day of the quarter
		that contains today, and it already includes the year
		(e.g. 2026-11-22 -> 2026-10-01). The quarter ends 3 months later.
		The filter is a half-open range:
			payment_date >= quarter_start AND payment_date < quarter_start + 3 months
		- CURRENT_DATE is evaluated every time the view is queried, so the view
		  is dynamic: on 2027-01-01 it automatically switches to Q1 2027.
		- Comparing year AND quarter at once avoids the classic bug of
		  "EXTRACT(QUARTER ...) = 4" which would mix Q4 of every year.
		- A range on the raw column (instead of EXTRACT(...) on the column) lets
		  PostgreSQL use an index on payment_date if one exists, and the
		  "< next quarter start" bound correctly includes payments made on the
		  last day of the quarter at e.g. 23:59:59.

	Why only categories WITH sales appear / how zero-sales categories are excluded:
		1) The query starts FROM payment and uses INNER JOINs, so a category
		   appears only if at least one payment of the current quarter can be
		   traced to it. A category without payments has no row to group.
		2) HAVING SUM(pay.amount) > 0 additionally removes categories whose
		   payments sum to 0 (e.g. only 0.00 payments or refunds).
		A LEFT JOIN from category would be needed to SHOW zero categories -
		that is exactly what we do NOT do here.

	Data that should NOT appear (examples):
		- payments from a previous quarter of the same year
		  (today = 2026-11-22 -> a payment on 2026-09-30 is Q3, excluded);
		- payments from the same quarter of another year
		  (a payment on 2007-11-01 is Q4 but of 2007, excluded);
		- the whole default dataset: payments are from past years only
		  (2007 or 2022, depending on the version of dvd_rental), so with the
		  default data the view correctly returns 0 rows;
		- categories such as "Music" if no film of that category was paid for
		  in the current quarter.

	How the view was verified (see tests below):
		1) Default data -> 0 rows (expected, there is no data for the current year).
		2) Inside a self-rolling-back DO block two test payments are inserted for today
		   (rentals are picked by subquery, not by hardcoded ID), plus one
		   payment dated in the previous quarter. The view shows only the
		   categories of today's payments with the right amounts, and does not
		   show the previous-quarter payment. Rolling back the block removes the test data.
		3) The view logic is equal to core.get_sales_revenue_by_category_qtr()
		   (Task 2) which returns real rows for the quarter of the latest payment.
*/
CREATE OR REPLACE VIEW core.sales_revenue_by_category_qtr AS
SELECT	cat.name			AS category,
		SUM(pay.amount)		AS total_sales_revenue
FROM	public.payment			pay
INNER JOIN public.rental		ren		ON pay.rental_id	= ren.rental_id
INNER JOIN public.inventory		inv		ON ren.inventory_id	= inv.inventory_id
INNER JOIN public.film_category	flmcat	ON inv.film_id		= flmcat.film_id
INNER JOIN public.category		cat		ON flmcat.category_id = cat.category_id
WHERE	pay.payment_date >= DATE_TRUNC('quarter', CURRENT_DATE)::DATE AND
		pay.payment_date <  (DATE_TRUNC('quarter', CURRENT_DATE) + INTERVAL '3 months')::DATE
GROUP BY cat.category_id,
		cat.name
HAVING	SUM(pay.amount) > 0
ORDER BY total_sales_revenue DESC,
		category;

COMMENT ON VIEW core.sales_revenue_by_category_qtr IS
	'Revenue (SUM(payment.amount)) per film category for the current quarter of the current year. '
	'Quarter = DATE_TRUNC(''quarter'', CURRENT_DATE); only categories with revenue > 0 are shown.';


--Test 1.1 (valid, default data): expected 0 rows - the dataset has no payments in the current year.
-- title: T1.1 view, current quarter
SELECT	srcq.category,
		srcq.total_sales_revenue
FROM	core.sales_revenue_by_category_qtr srcq;

--Test 1.2 (valid, controlled data): add 2 payments for "today" and 1 for the previous quarter,
--print the view, then undo everything.
--In some versions of dvd_rental public.payment is PARTITIONED by payment_date (monthly partitions
--only for the years that have data), so a payment dated today has no partition to go to
--(ERROR 23514 "no partition of relation payment found for row"). In that case the block first creates
--a test partition for the previous + current quarter. CREATE TABLE needs literal bounds, so it is
--built with FORMAT + EXECUTE. It is created inside the same savepoint, so it is rolled back too. The inner BEGIN ... EXCEPTION block is a savepoint: raising
--the custom error 'U0001' at its end rolls back every insert made inside it, so no test data is left,
--also in Auto-commit mode (DBeaver). Results are printed in the Output panel (RAISE NOTICE).
--expected: the categories of the two latest rentals, 10.00 each (20.00 if same category), no 500.00,
--then "test data rolled back, view rows now: 0".
DO $$
DECLARE
	v_row		RECORD;
	v_row_count	INTEGER;
BEGIN
	BEGIN
		--partitioned payment table: add a partition for the test dates (rolled back at the end)
		IF EXISTS (
			SELECT	1
			FROM	pg_catalog.pg_partitioned_table ptb
			WHERE	ptb.partrelid = 'public.payment'::REGCLASS
		) THEN
			BEGIN
				EXECUTE FORMAT(
					'CREATE TABLE public.payment_test_qtr PARTITION OF public.payment FOR VALUES FROM (%L) TO (%L)',
					DATE_TRUNC('quarter', CURRENT_DATE) - INTERVAL '3 months',
					DATE_TRUNC('quarter', CURRENT_DATE) + INTERVAL '3 months'
				);
			EXCEPTION WHEN invalid_object_definition OR duplicate_table THEN
				NULL;	--a partition (or DEFAULT partition) for these dates already exists - nothing to add
			END;
		END IF;

		--two payments today, for the two most recent rentals (no hardcoded IDs)
		INSERT INTO public.payment (customer_id, staff_id, rental_id, amount, payment_date)
		SELECT	ren.customer_id,
				ren.staff_id,
				ren.rental_id,
				10.00,
				CURRENT_TIMESTAMP
		FROM	public.rental ren
		WHERE	ren.rental_id IN (
					SELECT	ren_last.rental_id
					FROM	public.rental ren_last
					ORDER BY ren_last.rental_date DESC,
							ren_last.rental_id DESC
					LIMIT 2
				);

		--one payment on the last second of the PREVIOUS quarter - must NOT appear in the view
		INSERT INTO public.payment (customer_id, staff_id, rental_id, amount, payment_date)
		SELECT	ren.customer_id,
				ren.staff_id,
				ren.rental_id,
				500.00,
				DATE_TRUNC('quarter', CURRENT_DATE) - INTERVAL '1 second'
		FROM	public.rental ren
		WHERE	ren.rental_id = (
					SELECT	MIN(ren_first.rental_id)
					FROM	public.rental ren_first
				);

		FOR v_row IN
			SELECT	srcq.category,
					srcq.total_sales_revenue
			FROM	core.sales_revenue_by_category_qtr srcq
		LOOP
			RAISE NOTICE 'Test 1.2 view row: % = %', v_row.category, v_row.total_sales_revenue;
		END LOOP;

		RAISE EXCEPTION 'undo test data' USING ERRCODE = 'U0001';
	EXCEPTION WHEN SQLSTATE 'U0001' THEN
		NULL;	--expected: everything inserted inside this block is rolled back
	END;

	SELECT	COUNT(*)
	INTO	v_row_count
	FROM	core.sales_revenue_by_category_qtr srcq;

	RAISE NOTICE 'Test 1.2 OK, test data rolled back, view rows now: %', v_row_count;
END;
$$;


/*
	TASK 2. core.get_sales_revenue_by_category_qtr(p_quarter_date)

	Returns exactly the same result set as the view, but for any quarter.

	Why the parameter is needed:
		The view is fixed to CURRENT_DATE, and the default database has no data
		for the current year, so the view alone cannot be used for reports on
		past quarters (or to test the logic on real data). The parameter makes
		the same logic reusable for any quarter.

	Parameter design: ONE parameter of type DATE that represents
	"quarter + year" - any date inside the wanted quarter.
		'2022-04-15' -> Q2 2022 (2022-04-01 .. 2022-06-30)
		DEFAULT CURRENT_DATE -> the parameter is optional; calling the function
		without arguments gives the same result as the view.
		A DATE is used instead of two numbers (year, quarter) because the
		quarter is derived by DATE_TRUNC, so the year and quarter are always
		consistent and a "quarter 5" can not be represented at all.

	What happens if an INVALID quarter is passed:
		- impossible date (e.g. '2007-13-01' or '2007-02-30'): PostgreSQL rejects
		  the literal before the function starts:
		  ERROR: date/time field value out of range.
		- NULL: RAISE EXCEPTION 'Quarter date must not be NULL ...'.
		  (Without the check a NULL would silently return 0 rows and hide the
		  caller's mistake.)
		- a date in a FUTURE quarter: RAISE EXCEPTION - revenue cannot exist yet,
		  so this is treated as wrong input, not as "no data".
		A LANGUAGE SQL function cannot contain RAISE, so the checks call the
		small helper core.fn_raise_error() inside a CASE expression. CASE
		evaluates its branches in order, and the helper is VOLATILE, so it is
		executed only when its branch is reached.

	What happens if NO DATA exists for the quarter:
		The function returns an empty result set (0 rows), no error - the same
		behaviour as the view. "No sales in the quarter" is a valid business
		answer, not a failure. Example: Q4 2005 (no payments in any version).
*/

--helper: lets LANGUAGE SQL functions raise a readable exception
CREATE OR REPLACE FUNCTION core.fn_raise_error(p_message TEXT)
RETURNS DATE
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
	RAISE EXCEPTION '%', p_message
		USING ERRCODE = 'invalid_parameter_value';
END;
$$;

COMMENT ON FUNCTION core.fn_raise_error(TEXT) IS
	'Helper: raises an exception with the given message. Used in LANGUAGE SQL functions that cannot RAISE themselves.';


CREATE OR REPLACE FUNCTION core.get_sales_revenue_by_category_qtr(
	p_quarter_date DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
	category			TEXT,
	total_sales_revenue	NUMERIC
)
LANGUAGE sql
STABLE
AS $$
	WITH qtr AS (
		-- validation + quarter boundaries are computed once
		SELECT	CASE
					WHEN p_quarter_date IS NULL
						THEN core.fn_raise_error('Quarter date must not be NULL. Pass any date inside the wanted quarter, e.g. ''2007-04-15''.')
					WHEN DATE_TRUNC('quarter', p_quarter_date) > DATE_TRUNC('quarter', CURRENT_DATE)
						THEN core.fn_raise_error('Quarter of ' || p_quarter_date::TEXT || ' is in the future, no revenue can exist yet.')
					ELSE DATE_TRUNC('quarter', p_quarter_date)::DATE
				END AS qtr_start
	)
	SELECT	cat.name::TEXT		AS category,
			SUM(pay.amount)		AS total_sales_revenue
	FROM	public.payment			pay
	INNER JOIN public.rental		ren		ON pay.rental_id	= ren.rental_id
	INNER JOIN public.inventory		inv		ON ren.inventory_id	= inv.inventory_id
	INNER JOIN public.film_category	flmcat	ON inv.film_id		= flmcat.film_id
	INNER JOIN public.category		cat		ON flmcat.category_id = cat.category_id
	WHERE	pay.payment_date >= (SELECT qtr.qtr_start FROM qtr) AND
			pay.payment_date <  (SELECT (qtr.qtr_start + INTERVAL '3 months')::DATE FROM qtr)
	GROUP BY cat.category_id,
			cat.name
	HAVING	SUM(pay.amount) > 0
	ORDER BY total_sales_revenue DESC,
			category;
$$;

COMMENT ON FUNCTION core.get_sales_revenue_by_category_qtr(DATE) IS
	'Same result as view core.sales_revenue_by_category_qtr for the quarter that contains p_quarter_date (default CURRENT_DATE).';


--test 2.1 (valid): the quarter of the latest payment in the database (found by subquery, not hardcoded,
--so it works for any version of dvd_rental: 2007 or 2022 data) -> expected 16 category rows sorted by revenue.
-- title: T2.1 quarter of latest payment
SELECT	gsr.category,
		gsr.total_sales_revenue
FROM	core.get_sales_revenue_by_category_qtr(
			(SELECT MAX(pay.payment_date)::DATE FROM public.payment pay)
		) gsr;

--test 2.2 (valid, optional parameter): no argument = current quarter = same result as the view (expected 0 rows of difference).
-- title: T2.2 no arg = view (diff)
SELECT	gsr.category,
		gsr.total_sales_revenue
FROM	core.get_sales_revenue_by_category_qtr() gsr
EXCEPT
SELECT	srcq.category,
		srcq.total_sales_revenue
FROM	core.sales_revenue_by_category_qtr srcq;

--test 2.3 (edge, no data): Q4 2005 has no payments -> expected 0 rows, no error.
-- title: T2.3 Q4 2005 no data
SELECT	gsr.category,
		gsr.total_sales_revenue
FROM	core.get_sales_revenue_by_category_qtr('2005-11-01'::DATE) gsr;

--test 2.4 (invalid): NULL and a future quarter -> exceptions (caught here so the script continues).
DO $$
BEGIN
	BEGIN
		PERFORM core.get_sales_revenue_by_category_qtr(NULL);
	EXCEPTION WHEN invalid_parameter_value THEN
		RAISE NOTICE 'Test 2.4a OK, expected error: %', SQLERRM;
	END;

	BEGIN
		PERFORM core.get_sales_revenue_by_category_qtr((CURRENT_DATE + INTERVAL '1 year')::DATE);
	EXCEPTION WHEN invalid_parameter_value THEN
		RAISE NOTICE 'Test 2.4b OK, expected error: %', SQLERRM;
	END;
END;
$$;
--Note: core.get_sales_revenue_by_category_qtr('2007-13-01') fails before the function runs:
--ERROR: date/time field value out of range: "2007-13-01" (not executed here to keep the script error-free).


/*
	TASK 3. core.most_popular_films_by_countries(p_countries)

	Input: an array of country names, e.g. ARRAY['Afghanistan','Brazil','United States'].
	Output: one row per requested country that has rentals:
		country | film | rating | language | length | release_year | rental_count

	How "most popular" is defined: BY NUMBER OF RENTALS.
		A rental is the act of a customer taking the film, so the count of
		rentals made by customers who live in the country is the most direct
		measure of popularity. Revenue was not used as the main measure because
		it depends on rental_rate and late fees (an expensive film rented less
		often could "win"); revenue is only used as a tie-breaker.
		The country of a rental is the country of the customer's address:
		country -> city -> address -> customer -> rental -> inventory -> film.

	How ties are handled:
		ROW_NUMBER() OVER (PARTITION BY country ORDER BY rental_count DESC,
		revenue DESC, title ASC) and only row 1 is returned. So if two films
		have the same number of rentals, the one with the higher revenue wins;
		if the revenue is also equal, the alphabetically first title wins.
		The result is deterministic: exactly one film per country, and the same
		answer every run. (rental_count is returned so the reader can see the
		popularity value.)

	What happens if a country has no data / input is wrong:
		- NULL or empty array (or only NULL/blank elements): RAISE EXCEPTION.
		- a name that does not exist in public.country (typo, e.g. 'Brasil'):
		  RAISE EXCEPTION listing the unknown names. The whole call fails,
		  because silently skipping a typo would look like "no rentals".
		- the country exists but its customers have no rentals: RAISE NOTICE
		  "no rentals found for ..." and the country is simply absent from the
		  result; the other countries are still returned.
		- matching is case-insensitive and ignores surrounding spaces
		  ('brazil ', 'BRAZIL' -> Brazil); duplicates in the array are returned once.

	Note: the example in the task text has a typographic quote
	('United States’]) - that is a typo in the task; a straight quote must be used.
*/
CREATE OR REPLACE FUNCTION core.most_popular_films_by_countries(p_countries TEXT[])
RETURNS TABLE (
	country			TEXT,
	film			TEXT,
	rating			TEXT,
	language		TEXT,
	length			INTEGER,
	release_year	INTEGER,
	rental_count	BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
	v_unknown_countries		TEXT;
	v_no_rental_countries	TEXT;
BEGIN
	-- 1. input must contain at least one non-blank name
	IF p_countries IS NULL OR
		NOT EXISTS (
			SELECT	1
			FROM	UNNEST(p_countries) AS req(country_name)
			WHERE	NULLIF(TRIM(req.country_name), '') IS NOT NULL
		) THEN
		RAISE EXCEPTION 'Country list must contain at least one country name, e.g. ARRAY[''Brazil''].'
			USING ERRCODE = 'invalid_parameter_value';
	END IF;

	-- 2. every name must exist in public.country (case-insensitive)
	SELECT	STRING_AGG(DISTINCT TRIM(req.country_name), ', ')
	INTO	v_unknown_countries
	FROM	UNNEST(p_countries) AS req(country_name)
	WHERE	NULLIF(TRIM(req.country_name), '') IS NOT NULL AND
			NOT EXISTS (
				SELECT	1
				FROM	public.country cnt
				WHERE	UPPER(cnt.country) = UPPER(TRIM(req.country_name))
			);

	IF v_unknown_countries IS NOT NULL THEN
		RAISE EXCEPTION 'Country not found in public.country: %', v_unknown_countries
			USING ERRCODE = 'no_data_found';
	END IF;

	-- 3. existing countries without any rental -> notice only
	SELECT	STRING_AGG(cnt.country, ', ' ORDER BY cnt.country)
	INTO	v_no_rental_countries
	FROM	public.country cnt
	WHERE	UPPER(cnt.country) IN (
				SELECT	UPPER(TRIM(req.country_name))
				FROM	UNNEST(p_countries) AS req(country_name)
			) AND
			NOT EXISTS (
				SELECT	1
				FROM	public.city		cit
				INNER JOIN public.address	adr	ON cit.city_id		= adr.city_id
				INNER JOIN public.customer	cus	ON adr.address_id	= cus.address_id
				INNER JOIN public.rental	ren	ON cus.customer_id	= ren.customer_id
				WHERE	cit.country_id = cnt.country_id
			);

	IF v_no_rental_countries IS NOT NULL THEN
		RAISE NOTICE 'No rentals found for: % (not included in the result)', v_no_rental_countries;
	END IF;

	-- 4. one set-based query: count rentals per (country, film), rank, keep rank 1
	RETURN QUERY
	WITH film_stats AS (
		SELECT	cnt.country_id,
				cnt.country,
				inv.film_id,
				COUNT(DISTINCT ren.rental_id)	AS rental_count,
				COALESCE(SUM(pay.amount), 0)	AS revenue_total
		FROM	public.country			cnt
		INNER JOIN public.city			cit	ON cnt.country_id	= cit.country_id
		INNER JOIN public.address		adr	ON cit.city_id		= adr.city_id
		INNER JOIN public.customer		cus	ON adr.address_id	= cus.address_id
		INNER JOIN public.rental		ren	ON cus.customer_id	= ren.customer_id
		INNER JOIN public.inventory		inv	ON ren.inventory_id	= inv.inventory_id
		LEFT OUTER JOIN public.payment	pay	ON ren.rental_id	= pay.rental_id
		WHERE	UPPER(cnt.country) IN (
					SELECT	UPPER(TRIM(req.country_name))
					FROM	UNNEST(p_countries) AS req(country_name)
				)
		GROUP BY cnt.country_id,
				cnt.country,
				inv.film_id
	),
	ranked AS (
		SELECT	fst.country,
				fst.film_id,
				fst.rental_count,
				ROW_NUMBER() OVER (
					PARTITION BY fst.country_id
					ORDER BY fst.rental_count DESC,
							fst.revenue_total DESC,
							flm.title ASC
				) AS popularity_rank
		FROM	film_stats		fst
		INNER JOIN public.film	flm	ON fst.film_id = flm.film_id
	)
	SELECT	rnk.country::TEXT,
			flm.title::TEXT,
			flm.rating::TEXT,
			TRIM(lng.name)::TEXT,
			flm.length::INTEGER,
			flm.release_year::INTEGER,
			rnk.rental_count
	FROM	ranked				rnk
	INNER JOIN public.film		flm	ON rnk.film_id		= flm.film_id
	INNER JOIN public.language	lng	ON flm.language_id	= lng.language_id
	WHERE	rnk.popularity_rank = 1
	ORDER BY rnk.country;
END;
$$;

COMMENT ON FUNCTION core.most_popular_films_by_countries(TEXT[]) IS
	'Most rented film per country (customer address country). Ties: higher revenue, then title A-Z. One row per country.';


--Test 3.1 (valid): expected 3 rows - one film per country.
-- title: T3.1 three countries
SELECT	mpf.country,
		mpf.film,
		mpf.rating,
		mpf.language,
		mpf.length,
		mpf.release_year,
		mpf.rental_count
FROM	core.most_popular_films_by_countries(ARRAY['Afghanistan', 'Brazil', 'United States']) mpf;

--Test 3.2 (edge): different case, spaces and a duplicate -> still exactly one row (Brazil).
-- title: T3.2 case and duplicates
SELECT	mpf.country,
		mpf.film,
		mpf.rental_count
FROM	core.most_popular_films_by_countries(ARRAY['  brazil ', 'BRAZIL']) mpf;

--Test 3.3 (invalid): unknown country and empty array -> exceptions (caught).
DO $$
BEGIN
	BEGIN
		PERFORM core.most_popular_films_by_countries(ARRAY['Brazil', 'Brasil', 'Narnia']);
	EXCEPTION WHEN no_data_found THEN
		RAISE NOTICE 'Test 3.3a OK, expected error: %', SQLERRM;
	END;

	BEGIN
		PERFORM core.most_popular_films_by_countries(ARRAY[]::TEXT[]);
	EXCEPTION WHEN invalid_parameter_value THEN
		RAISE NOTICE 'Test 3.3b OK, expected error: %', SQLERRM;
	END;
END;
$$;


/*
	TASK 4. PL/pgSQL function core.films_in_stock_by_title(p_title_pattern)

	Output:
		row_num | film_title | language | customer_name | rental_date
	One row per film whose title matches the pattern AND that has at least
	one copy in stock right now. customer_name / rental_date show the last
	rental of that film (NULL if the film was never rented).

	How pattern matching works (LIKE, %):
		ILIKE compares the title with a pattern where
			%  = any sequence of characters (also empty),
			_  = exactly one character.
		'%love%' = "contains love anywhere", 'love%' = "starts with love".
		If the caller passes text without any wildcard (e.g. 'love'), the
		function wraps it as '%love%', so a partial match is still done.

	Case sensitivity:
		ILIKE is case-insensitive, so '%love%' finds 'LOVE SUICIDES',
		'Love Suicides' and 'STRANGELOVE DESIRE'. LIKE would be case-sensitive:
		titles are stored in UPPER case in one version of dvd_rental and in
		Title case in another, so LIKE '%love%' would return nothing (or only
		'Strangelove Desire') and miss the other matches.

	rental_date is cast to TIMESTAMP because rental.rental_date is TIMESTAMP in
	one version of dvd_rental and TIMESTAMPTZ in another; the cast makes the
	result type match RETURNS TABLE in both (shown in the session time zone).

	"In stock" definition (same rule as public.inventory_in_stock):
		a copy (inventory row) is in stock when it has no rental with
		return_date IS NULL. A film is listed if at least one copy is in stock.

	Performance - what may become slow on large data, and what is done:
		- title ILIKE '%...%' with a leading % cannot use the btree index
		  idx_title, so this is a sequential scan of film. That is why it is the
		  FIRST step (CTE matched_films): all later work is done only for the
		  few matched films, not for the whole catalogue.
		  On a really big table a trigram index would fix it:
		  CREATE EXTENSION pg_trgm; CREATE INDEX ... USING gin (title gin_trgm_ops);
		- the stock check is a NOT EXISTS anti-join on rental by inventory_id
		  (indexed), and it stops at the first open rental. The existing
		  function inventory_in_stock() is deliberately NOT called per row,
		  because it runs 2 extra queries for every copy.
		- the last rental per film is found with DISTINCT ON over the rentals of
		  the matched films only, instead of sorting the whole rental table.
		- row_num is produced by ROW_NUMBER() in the same query - no loop, no
		  second pass.

	What happens if:
		- multiple matches: every matching in-stock film is returned, ordered by
		  title, row_num = 1, 2, 3 ... (ROW_NUMBER over the ordered result).
		- no matches: one message row is returned (row_num NULL, message in
		  film_title) + RAISE NOTICE. Two different messages:
		    'No film with title matching ''%xyz%'' was found'           - title does not exist
		    'Film(s) matching ''%xyz%'' exist but are not in stock'      - all copies are rented out / no copies
		- NULL or blank pattern: RAISE EXCEPTION (it would match nothing or
		  everything, which is never the user's intention).
*/
CREATE OR REPLACE FUNCTION core.films_in_stock_by_title(p_title_pattern TEXT)
RETURNS TABLE (
	row_num			BIGINT,
	film_title		TEXT,
	language		TEXT,
	customer_name	TEXT,
	rental_date		TIMESTAMP
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
	v_pattern		TEXT;
	v_title_exists	BOOLEAN;
BEGIN
	IF p_title_pattern IS NULL OR TRIM(p_title_pattern) = '' THEN
		RAISE EXCEPTION 'Title pattern must not be NULL or empty, e.g. ''%%love%%''.'
			USING ERRCODE = 'invalid_parameter_value';
	END IF;

	v_pattern := TRIM(p_title_pattern);

	-- no wildcard given -> make it a "contains" search
	IF POSITION('%' IN v_pattern) = 0 AND POSITION('_' IN v_pattern) = 0 THEN
		v_pattern := '%' || v_pattern || '%';
	END IF;

	RETURN QUERY
	WITH matched_films AS (
		SELECT	flm.film_id,
				flm.title,
				flm.language_id
		FROM	public.film flm
		WHERE	flm.title ILIKE v_pattern
	),
	films_in_stock AS (
		SELECT	DISTINCT inv.film_id
		FROM	public.inventory inv
		WHERE	inv.film_id IN (SELECT mtf.film_id FROM matched_films mtf) AND
				NOT EXISTS (
					SELECT	1
					FROM	public.rental ren_open
					WHERE	ren_open.inventory_id = inv.inventory_id AND
							ren_open.return_date IS NULL
				)
	),
	last_rental AS (
		SELECT	DISTINCT ON (inv.film_id)
				inv.film_id,
				cus.first_name || ' ' || cus.last_name	AS customer_name,
				ren.rental_date
		FROM	public.inventory		inv
		INNER JOIN public.rental		ren	ON inv.inventory_id	= ren.inventory_id
		INNER JOIN public.customer		cus	ON ren.customer_id	= cus.customer_id
		WHERE	inv.film_id IN (SELECT fis.film_id FROM films_in_stock fis)
		ORDER BY inv.film_id,
				ren.rental_date DESC
	)
	SELECT	ROW_NUMBER() OVER (ORDER BY mtf.title, mtf.film_id)	AS row_num,
			mtf.title::TEXT										AS film_title,
			TRIM(lng.name)::TEXT								AS language,
			lst.customer_name::TEXT								AS customer_name,
			lst.rental_date::TIMESTAMP							AS rental_date
	FROM	matched_films				mtf
	INNER JOIN films_in_stock			fis	ON mtf.film_id		= fis.film_id
	INNER JOIN public.language			lng	ON mtf.language_id	= lng.language_id
	LEFT OUTER JOIN last_rental			lst	ON mtf.film_id		= lst.film_id
	ORDER BY mtf.title,
			mtf.film_id;

	-- nothing returned -> return one message row explaining why
	IF NOT FOUND THEN
		SELECT	EXISTS (
					SELECT	1
					FROM	public.film flm
					WHERE	flm.title ILIKE v_pattern
				)
		INTO	v_title_exists;

		row_num			:= NULL;
		language		:= NULL;
		customer_name	:= NULL;
		rental_date		:= NULL;

		IF v_title_exists THEN
			film_title := FORMAT('Film(s) matching %L exist but are not in stock', v_pattern);
		ELSE
			film_title := FORMAT('No film with title matching %L was found', v_pattern);
		END IF;

		RAISE NOTICE '%', film_title;
		RETURN NEXT;
	END IF;
END;
$$;

COMMENT ON FUNCTION core.films_in_stock_by_title(TEXT) IS
	'In-stock films whose title matches an ILIKE pattern (auto-wrapped in % if no wildcard), with last renter. Returns a message row if nothing is found.';


--Test 4.1 (valid, multiple matches): expected several rows, row_num 1..N, titles contain "love" in any case.
-- title: T4.1 %love%
SELECT	fst.row_num,
		fst.film_title,
		fst.language,
		fst.customer_name,
		fst.rental_date
FROM	core.films_in_stock_by_title('%love%') fst;

--Test 4.2 (edge): no wildcard and lower case -> treated as '%LOVE%', same result as 4.1.
-- title: T4.2 love no wildcard
SELECT	fst.row_num,
		fst.film_title
FROM	core.films_in_stock_by_title('love') fst;

--Test 4.3 (edge, no match): expected 1 message row 'No film with title matching ... was found'.
-- title: T4.3 no match
SELECT	fst.row_num,
		fst.film_title
FROM	core.films_in_stock_by_title('%zzz_no_such_film%') fst;

--Test 4.4 (invalid): empty pattern -> exception (caught).
DO $$
BEGIN
	PERFORM core.films_in_stock_by_title('   ');
EXCEPTION WHEN invalid_parameter_value THEN
	RAISE NOTICE 'Test 4.4 OK, expected error: %', SQLERRM;
END;
$$;


/*
	TASK 5. core.new_movie(p_title, p_release_year, p_language_name)

	Inserts a film with: rental_rate 4.99, rental_duration 3, replacement_cost 19.99.
	Optional parameters:
		p_release_year  DEFAULT current year  (EXTRACT(YEAR FROM CURRENT_DATE))
		p_language_name DEFAULT 'Klingon'
	An explicit NULL for an optional parameter also means "use the default".
	Returns the new film_id.

	Pre-requisite: 'Klingon' does not exist in the default public.language, so
	the script adds it once (INSERT ... WHERE NOT EXISTS, rerunnable) - otherwise
	the default call would always fail the language check.

	How the unique ID is generated:
		film_id is NOT passed in the INSERT, so the column default
		nextval('film_film_id_seq') generates it. A sequence is safe under
		concurrency (two sessions never get the same value), unlike MAX(id)+1.
		Before inserting, the sequence is moved forward with setval() if it is
		behind MAX(film_id) (this happens when rows were loaded with explicit
		IDs), so nextval can never return an ID that is already used.

	How duplicates are prevented / what happens if the movie already exists:
		- titles are compared case- and space-insensitively:
		  UPPER(TRIM(title)) = UPPER(TRIM(p_title)), so 'Academy Dinosaur' and
		  ' ACADEMY DINOSAUR ' are the same movie;
		- if a match exists: RAISE EXCEPTION 'Movie "..." already exists
		  (film_id = ...)' with ERRCODE unique_violation, nothing is inserted;
		- race condition: two sessions could both check "not exists" and both
		  insert. pg_advisory_xact_lock(hashtext(normalised title)) serialises
		  calls for the SAME title until the transaction ends, so the second
		  session waits and then sees the first one's row.

	How language existence is validated:
		SELECT language_id ... WHERE UPPER(TRIM(name)) = UPPER(TRIM(p_language_name)).
		language.name is CHAR(20) (padded with spaces) - TRIM/UPPER make
		'klingon' match 'Klingon             '. If NOT FOUND -> RAISE EXCEPTION
		'Language ... does not exist'. The language_id is looked up, never
		hardcoded.

	Other validation: title NULL/blank or longer than 255 chars -> exception;
	release year outside 1901..2155 (domain public.year) -> exception.

	What happens if the insertion fails / how consistency is preserved:
		- a PL/pgSQL function runs inside the caller's transaction and is
		  atomic: if anything raises, every change made by the call is rolled
		  back, so a half-inserted film is impossible. The only
		  non-transactional part is the sequence (nextval/setval are never
		  rolled back) - a failed call can leave a gap in film_id values, but
		  never a duplicate.
		- the INSERT is in its own BEGIN ... EXCEPTION block that re-raises any
		  DB error (FK, check, not-null, trigger errors) with a clear message
		  and the original SQLSTATE, so the caller knows what failed.
		- all checks run BEFORE the insert, and the FK to language plus the
		  NOT NULL constraints of film are still enforced by the database.
		- the fulltext column is filled by the existing trigger
		  film_fulltext_trigger, last_update by its DEFAULT now().
*/

-- Pre-requisite data: default language for new_movie
INSERT INTO public.language (name)
SELECT	'Klingon'
WHERE	NOT EXISTS (
			SELECT	1
			FROM	public.language lng
			WHERE	UPPER(TRIM(lng.name)) = 'KLINGON'
		);


CREATE OR REPLACE FUNCTION core.new_movie(
	p_title			TEXT,
	p_release_year	INTEGER	DEFAULT EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER,
	p_language_name	TEXT	DEFAULT 'Klingon'
)
RETURNS INTEGER
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
	v_title				TEXT;
	v_release_year		INTEGER;
	v_language_name		TEXT;
	v_language_id		INTEGER;
	v_existing_film_id	INTEGER;
	v_sequence_name		TEXT;
	v_new_film_id		INTEGER;
BEGIN
	-- 1. normalise and validate input
	v_title			:= TRIM(p_title);
	v_release_year	:= COALESCE(p_release_year, EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER);
	v_language_name	:= COALESCE(NULLIF(TRIM(p_language_name), ''), 'Klingon');

	IF v_title IS NULL OR v_title = '' THEN
		RAISE EXCEPTION 'Movie title must not be NULL or empty.'
			USING ERRCODE = 'invalid_parameter_value';
	END IF;

	IF LENGTH(v_title) > 255 THEN
		RAISE EXCEPTION 'Movie title is too long (% chars, max 255).', LENGTH(v_title)
			USING ERRCODE = 'invalid_parameter_value';
	END IF;

	IF v_release_year NOT BETWEEN 1901 AND 2155 THEN
		RAISE EXCEPTION 'Release year % is out of the allowed range 1901..2155.', v_release_year
			USING ERRCODE = 'invalid_parameter_value';
	END IF;

	-- 2. language must exist
	SELECT	lng.language_id
	INTO	v_language_id
	FROM	public.language lng
	WHERE	UPPER(TRIM(lng.name)) = UPPER(v_language_name);

	IF NOT FOUND THEN
		RAISE EXCEPTION 'Language "%" does not exist in public.language.', v_language_name
			USING ERRCODE = 'foreign_key_violation';
	END IF;

	-- 3. no duplicates: lock this title for the transaction, then check
	PERFORM pg_advisory_xact_lock(HASHTEXT('core.new_movie:' || UPPER(v_title)));

	SELECT	flm.film_id
	INTO	v_existing_film_id
	FROM	public.film flm
	WHERE	UPPER(TRIM(flm.title)) = UPPER(v_title)
	LIMIT 1;

	IF FOUND THEN
		RAISE EXCEPTION 'Movie "%" already exists (film_id = %).', v_title, v_existing_film_id
			USING ERRCODE = 'unique_violation';
	END IF;

	-- 4. make sure the sequence is ahead of existing IDs
	v_sequence_name := COALESCE(pg_get_serial_sequence('public.film', 'film_id'), 'public.film_film_id_seq');

	PERFORM SETVAL(
		v_sequence_name,
		GREATEST(
			COALESCE((SELECT MAX(flm.film_id) FROM public.film flm), 0),
			COALESCE(pg_sequence_last_value(v_sequence_name::REGCLASS), 0),
			1
		)
	);

	-- 5. insert; any DB error is re-raised with context
	BEGIN
		INSERT INTO public.film (title, release_year, language_id, rental_duration, rental_rate, replacement_cost)
		VALUES (v_title, v_release_year, v_language_id, 3, 4.99, 19.99)
		RETURNING film_id INTO v_new_film_id;
	EXCEPTION WHEN OTHERS THEN
		RAISE EXCEPTION 'Insert of movie "%" failed: %', v_title, SQLERRM
			USING ERRCODE = SQLSTATE;
	END;

	RAISE NOTICE 'Movie "%" inserted with film_id = %.', v_title, v_new_film_id;
	RETURN v_new_film_id;
END;
$$;

COMMENT ON FUNCTION core.new_movie(TEXT, INTEGER, TEXT) IS
	'Inserts a film (rate 4.99, duration 3, replacement 19.99). Optional: release year (default current year), language (default Klingon). Raises on duplicate title or unknown language.';


--test 5.1 (valid, defaults): insert once; on rerun the guard skips it, so the script stays error-free.
-- title: T5.1 new_movie defaults
SELECT	core.new_movie('Aiym Test Movie Defaults') AS new_film_id
WHERE	NOT EXISTS (
			SELECT	1
			FROM	public.film flm
			WHERE	UPPER(flm.title) = UPPER('Aiym Test Movie Defaults')
		);

--test 5.2 (valid, optional parameters given): release year 2020, language English.
-- title: T5.2 new_movie English 2020
SELECT	core.new_movie('Aiym Test Movie English', 2020, 'english') AS new_film_id
WHERE	NOT EXISTS (
			SELECT	1
			FROM	public.film flm
			WHERE	UPPER(flm.title) = UPPER('Aiym Test Movie English')
		);

--check: expected 2 rows, Klingon / current year and English / 2020, rate 4.99, duration 3, cost 19.99.
-- title: T5 check inserted movies
SELECT	flm.film_id,
		flm.title,
		flm.release_year,
		TRIM(lng.name)		AS language,
		flm.rental_rate,
		flm.rental_duration,
		flm.replacement_cost
FROM	public.film				flm
INNER JOIN public.language		lng	ON flm.language_id = lng.language_id
WHERE	flm.title IN ('Aiym Test Movie Defaults', 'Aiym Test Movie English')
ORDER BY flm.title;

--test 5.3 (invalid): duplicate (different case), unknown language, empty title, bad year -> exceptions (caught).
DO $$
BEGIN
	BEGIN
		PERFORM core.new_movie('  academy dinosaur ');
	EXCEPTION WHEN unique_violation THEN
		RAISE NOTICE 'Test 5.3a OK, expected error: %', SQLERRM;
	END;

	BEGIN
		PERFORM core.new_movie('Aiym Test Movie Elvish', 2024, 'Elvish');
	EXCEPTION WHEN foreign_key_violation THEN
		RAISE NOTICE 'Test 5.3b OK, expected error: %', SQLERRM;
	END;

	BEGIN
		PERFORM core.new_movie(NULL);
	EXCEPTION WHEN invalid_parameter_value THEN
		RAISE NOTICE 'Test 5.3c OK, expected error: %', SQLERRM;
	END;

	BEGIN
		PERFORM core.new_movie('Aiym Test Movie Old', 1800);
	EXCEPTION WHEN invalid_parameter_value THEN
		RAISE NOTICE 'Test 5.3d OK, expected error: %', SQLERRM;
	END;
END;
$$;