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
    3. "Top-N" tasks (1.3, 2.1, 2.2) return exactly N rows, as the tasks ask:
       FETCH FIRST N ROWS ONLY with a deterministic tie-breaker after the
       measure (name, then id), so the same rows come back on every run.
       "Longest gap" tasks (Part 3) have no N, so all actors sharing the
       maximum are returned (FETCH FIRST 1 ROWS WITH TIES or = MAX/MIN).
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
-- only films that have the 'Animation' category stay in the result.
SELECT  flm.title,
        flm.release_year,
        flm.rental_rate
FROM    public.film             flm
INNER JOIN public.film_category flmcat  ON flm.film_id          = flmcat.film_id
INNER JOIN public.category      cat     ON flmcat.category_id   = cat.category_id
WHERE   UPPER(cat.name)     = 'ANIMATION'   AND
        flm.release_year    BETWEEN 2017 AND 2019   AND
        flm.rental_rate     > 1
ORDER BY flm.title;
 
-- 1.1 SUBQUERY solution
-- subquery returns the ids of all animation films;
-- the outer query keeps films whose id is in that list.
-- Its INNER JOIN drops film_category rows whose category is not 'Animation'.
SELECT  flm.title,
        flm.release_year,
        flm.rental_rate
FROM    public.film flm
WHERE   flm.film_id IN (
            SELECT  flmcat.film_id
            FROM    public.film_category    flmcat
            INNER JOIN public.category  cat     ON flmcat.category_id = cat.category_id
            WHERE   UPPER(cat.name) = 'ANIMATION'
        )                                   AND
        flm.release_year    BETWEEN 2017 AND 2019   AND
        flm.rental_rate     > 1
ORDER BY flm.title;
 
-- 1.1 CTE solution
-- prepares the list of animation film ids; INNER JOIN with it keeps only animation films.
WITH animation_films AS (
    SELECT  flmcat.film_id
    FROM    public.film_category    flmcat
    INNER JOIN public.category  cat     ON flmcat.category_id = cat.category_id
    WHERE   UPPER(cat.name) = 'ANIMATION'
)
SELECT  flm.title,
        flm.release_year,
        flm.rental_rate
FROM    public.film         flm
INNER JOIN animation_films  anf     ON flm.film_id = anf.film_id
WHERE   flm.release_year    BETWEEN 2017 AND 2019   AND
        flm.rental_rate     > 1
ORDER BY flm.title;
 
/*
    1.1 Comparison
    - JOIN: shortest and easiest to read; the optimizer handles it best.
                Risk: if a film had the same category twice it would be
                duplicated (impossible here - PK of film_category is
                (film_id, category_id)).
    - SUBQUERY: IN (...) can never duplicate films, and it clearly separates
                "which films are animation" from "which of them match the
                filters". Slightly harder to read when nested.
    - CTE: most readable - the animation list has a name and can be
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
-- The date filter is in the ON clause of the LEFT JOIN to payment (not in
-- WHERE): payments are filtered early, and stores without April+ payments
-- are still kept. A WHERE filter on payment would remove those stores and
-- turn the LEFT JOINs into INNER JOINs.
-- COALESCE turns the NULL sum of a store without payments into 0.
SELECT  CONCAT_WS(', ', adr.address, NULLIF(TRIM(adr.address2), ''))    AS store_address,
        COALESCE(SUM(pmt.amount), 0)                                    AS revenue
FROM    public.store            str
INNER JOIN public.address   adr     ON str.address_id       = adr.address_id
LEFT JOIN public.inventory  inv     ON str.store_id         = inv.store_id
LEFT JOIN public.rental     rnt     ON inv.inventory_id     = rnt.inventory_id
LEFT JOIN public.payment    pmt     ON rnt.rental_id        = pmt.rental_id
                                   AND pmt.payment_date     >= DATE '2017-04-01'
GROUP BY str.store_id,
        adr.address,
        adr.address2
ORDER BY revenue DESC;
 
-- 1.2 SUBQUERY solution
-- The derived table calculates revenue per store id (INNER JOINs: only
-- payments that can be traced to a store copy).
-- LEFT JOIN from store keeps stores that do not appear in the derived table;
-- COALESCE turns their NULL revenue into 0.
SELECT  CONCAT_WS(', ', adr.address, NULLIF(TRIM(adr.address2), ''))    AS store_address,
        COALESCE(strrev.revenue, 0)                                     AS revenue
FROM    public.store            str
INNER JOIN public.address   adr     ON str.address_id = adr.address_id
LEFT JOIN (
            SELECT  inv.store_id,
                    SUM(pmt.amount) AS revenue
            FROM    public.payment          pmt
            INNER JOIN public.rental        rnt     ON pmt.rental_id    = rnt.rental_id
            INNER JOIN public.inventory inv     ON rnt.inventory_id = inv.inventory_id
            WHERE   pmt.payment_date >= DATE '2017-04-01'
            GROUP BY inv.store_id
        ) strrev                        ON str.store_id = strrev.store_id
ORDER BY revenue DESC;
 
-- 1.2 CTE solution
-- Same logic as the subquery, but the revenue calculation is a named step.
WITH store_revenue AS (
    SELECT  inv.store_id,
            SUM(pmt.amount) AS revenue
    FROM    public.payment          pmt
    INNER JOIN public.rental        rnt     ON pmt.rental_id    = rnt.rental_id
    INNER JOIN public.inventory inv     ON rnt.inventory_id = inv.inventory_id
    WHERE   pmt.payment_date >= DATE '2017-04-01'
    GROUP BY inv.store_id
)
SELECT  CONCAT_WS(', ', adr.address, NULLIF(TRIM(adr.address2), ''))    AS store_address,
        COALESCE(strrev.revenue, 0)                                     AS revenue
FROM    public.store            str
INNER JOIN public.address   adr     ON str.address_id   = adr.address_id
LEFT JOIN store_revenue     strrev  ON str.store_id     = strrev.store_id
ORDER BY revenue DESC;
 
/*
    1.2 Comparison
    - JOIN: one flat query; the date filter in the ON clause filters
                payments early (an index on payment_date can be used) and
                keeps every store. But all inventory/rental rows are still
                joined before grouping - the most work on a large table.
    - SUBQUERY: filters payments by date first (index can be used), groups
                them, and only then joins the tiny result (one row per store)
                to store/address. Efficient, but the nested block makes the
                query harder to read.
    - CTE: same efficiency as the subquery; the revenue step has a name
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
    - Exactly 5 rows are returned (FETCH FIRST 5 ROWS ONLY). If actors tie
      on number_of_movies, last_name, first_name and then actor_id decide
      the order, so the same 5 actors come back on every run.
---------------------------------------------------------------------------- */
 
-- 1.3 JOIN solution
-- INNER JOINs: only actors that have at least one film released since 2015.
SELECT  act.first_name,
        act.last_name,
        COUNT(flmact.film_id)   AS number_of_movies
FROM    public.actor                act
INNER JOIN public.film_actor    flmact  ON act.actor_id     = flmact.actor_id
INNER JOIN public.film          flm     ON flmact.film_id   = flm.film_id
WHERE   flm.release_year >= 2015
GROUP BY act.actor_id,
        act.first_name,
        act.last_name
ORDER BY number_of_movies DESC,
        act.last_name,
        act.first_name,
        act.actor_id
FETCH FIRST 5 ROWS ONLY;
 
-- 1.3 SUBQUERY solution
-- The derived table counts films per actor_id; INNER JOIN with actor adds
-- the names (all actor_ids in the derived table exist in actor).
SELECT  act.first_name,
        act.last_name,
        actcnt.number_of_movies
FROM    public.actor act
INNER JOIN (
            SELECT  flmact.actor_id,
                    COUNT(flmact.film_id)   AS number_of_movies
            FROM    public.film_actor   flmact
            INNER JOIN public.film  flm     ON flmact.film_id = flm.film_id
            WHERE   flm.release_year >= 2015
            GROUP BY flmact.actor_id
        ) actcnt                    ON act.actor_id = actcnt.actor_id
ORDER BY actcnt.number_of_movies DESC,
        act.last_name,
        act.first_name,
        act.actor_id
FETCH FIRST 5 ROWS ONLY;
 
-- 1.3 CTE solution
WITH actor_movie_count AS (
    SELECT  flmact.actor_id,
            COUNT(flmact.film_id)   AS number_of_movies
    FROM    public.film_actor   flmact
    INNER JOIN public.film  flm     ON flmact.film_id = flm.film_id
    WHERE   flm.release_year >= 2015
    GROUP BY flmact.actor_id
)
SELECT  act.first_name,
        act.last_name,
        amc.number_of_movies
FROM    public.actor            act
INNER JOIN actor_movie_count    amc     ON act.actor_id = amc.actor_id
ORDER BY amc.number_of_movies DESC,
        act.last_name,
        act.first_name,
        act.actor_id
FETCH FIRST 5 ROWS ONLY;
 
/*
    1.3 Comparison
    - JOIN: compact; but GROUP BY has to list the name columns too, and
                names are carried through the whole aggregation.
    - SUBQUERY: counts on narrow film_actor rows (ids only) and joins names
                afterwards - slightly less data to group; nested and harder
                to read.
    - CTE: same plan as the subquery, readable top-to-bottom; the count
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
    - NULL handling: a year with no films of a genre shows 0, never NULL.
      COUNT ignores NULLs and returns 0 (not NULL) when nothing matched, so
      no COALESCE is needed. Films with NULL release_year are excluded -
      they cannot be placed on a timeline.
    - No DISTINCT is needed: the PK of film_category is
      (film_id, category_id), so a film appears at most once per genre.
---------------------------------------------------------------------------- */
 
-- 1.4 JOIN solution
-- LEFT JOINs: every film (and so every year) stays, even films without a
-- category. Conditional aggregation counts each genre in its own column:
-- CASE returns 1 for a matching genre and NULL otherwise; COUNT counts the 1s.
SELECT  flm.release_year,
        COUNT(CASE WHEN UPPER(cat.name) = 'DRAMA'       THEN 1 END)     AS number_of_drama_movies,
        COUNT(CASE WHEN UPPER(cat.name) = 'TRAVEL'      THEN 1 END)     AS number_of_travel_movies,
        COUNT(CASE WHEN UPPER(cat.name) = 'DOCUMENTARY' THEN 1 END)     AS number_of_documentary_movies
FROM    public.film                 flm
LEFT JOIN public.film_category  flmcat  ON flm.film_id          = flmcat.film_id
LEFT JOIN public.category       cat     ON flmcat.category_id   = cat.category_id
WHERE   flm.release_year IS NOT NULL
GROUP BY flm.release_year
ORDER BY flm.release_year DESC;
 
-- 1.4 SUBQUERY solution
-- Outer query: list of distinct years. Each column is a correlated scalar
-- subquery counting films of one genre in that year (INNER JOINs inside:
-- only films that have the genre). COUNT returns 0 for years with no films
-- of that genre.
SELECT  yrs.release_year,
        (
            SELECT  COUNT(*)
            FROM    public.film                 flm
            INNER JOIN public.film_category flmcat  ON flm.film_id          = flmcat.film_id
            INNER JOIN public.category      cat     ON flmcat.category_id   = cat.category_id
            WHERE   UPPER(cat.name)     = 'DRAMA'   AND
                    flm.release_year    = yrs.release_year
        )                                               AS number_of_drama_movies,
        (
            SELECT  COUNT(*)
            FROM    public.film                 flm
            INNER JOIN public.film_category flmcat  ON flm.film_id          = flmcat.film_id
            INNER JOIN public.category      cat     ON flmcat.category_id   = cat.category_id
            WHERE   UPPER(cat.name)     = 'TRAVEL'  AND
                    flm.release_year    = yrs.release_year
        )                                               AS number_of_travel_movies,
        (
            SELECT  COUNT(*)
            FROM    public.film                 flm
            INNER JOIN public.film_category flmcat  ON flm.film_id          = flmcat.film_id
            INNER JOIN public.category      cat     ON flmcat.category_id   = cat.category_id
            WHERE   UPPER(cat.name)     = 'DOCUMENTARY' AND
                    flm.release_year    = yrs.release_year
        )                                               AS number_of_documentary_movies
FROM    (
            SELECT  DISTINCT flm.release_year
            FROM    public.film flm
            WHERE   flm.release_year IS NOT NULL
        ) yrs
ORDER BY yrs.release_year DESC;
 
-- 1.4 CTE solution
-- film_genres: one row per (film, category) with the release year and the
-- genre name in upper case. LEFT JOINs keep films without a category, so
-- every year is present. The final query is a single aggregation.
WITH film_genres AS (
    SELECT  flm.release_year,
            UPPER(cat.name)     AS genre
    FROM    public.film                 flm
    LEFT JOIN public.film_category  flmcat  ON flm.film_id          = flmcat.film_id
    LEFT JOIN public.category       cat     ON flmcat.category_id   = cat.category_id
    WHERE   flm.release_year IS NOT NULL
)
SELECT  flg.release_year,
        COUNT(CASE WHEN flg.genre = 'DRAMA'       THEN 1 END)   AS number_of_drama_movies,
        COUNT(CASE WHEN flg.genre = 'TRAVEL'      THEN 1 END)   AS number_of_travel_movies,
        COUNT(CASE WHEN flg.genre = 'DOCUMENTARY' THEN 1 END)   AS number_of_documentary_movies
FROM    film_genres flg
GROUP BY flg.release_year
ORDER BY flg.release_year DESC;
 
/*
    1.4 Comparison
    - JOIN: one pass over film/film_category/category with conditional
                aggregation - efficient and short. Needs care: a WHERE filter
                on cat.name would remove years without these genres.
    - SUBQUERY: easy to understand column by column, but each correlated
                subquery runs once per year (3 x number of years executions)
                and the code is repeated three times - slowest and hardest to
                maintain.
    - CTE: same single aggregation as the JOIN version; the CTE names the
                "film + genre" step, so the final query only counts. Same
                performance as the JOIN version, slightly longer.
    Production choice: JOIN - one short query with one aggregation; the CTE
    version is a good alternative if the "film + genre" step is reused.
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
    - If two payments share the exact latest timestamp, the one with the
      higher payment_id (registered later) is taken as the last payment.
      All three versions use this same rule, so they always return the same
      store and exactly one row per employee.
    - Exactly 3 rows are returned (FETCH FIRST 3 ROWS ONLY). If employees
      tie on revenue, last_name, first_name and then staff_id decide the
      order.
---------------------------------------------------------------------------- */
 
-- 2.1 CTE solution
-- staff_revenue: revenue per employee in 2017.
-- last_payment_date: time of each employee's latest 2017 payment.
-- last_payment: id of that latest payment (higher payment_id on a tie).
-- last_store: store of that payment (payment -> rental -> inventory).
-- Final INNER JOINs: only employees that have 2017 revenue are shown.
WITH staff_revenue AS (
    SELECT  pmt.staff_id,
            SUM(pmt.amount) AS revenue
    FROM    public.payment pmt
    WHERE   pmt.payment_date >= DATE '2017-01-01'   AND
            pmt.payment_date <  DATE '2018-01-01'
    GROUP BY pmt.staff_id
),
last_payment_date AS (
    SELECT  pmt.staff_id,
            MAX(pmt.payment_date)   AS last_payment_date
    FROM    public.payment pmt
    WHERE   pmt.payment_date >= DATE '2017-01-01'   AND
            pmt.payment_date <  DATE '2018-01-01'
    GROUP BY pmt.staff_id
),
last_payment AS (
    SELECT  pmt.staff_id,
            MAX(pmt.payment_id)     AS last_payment_id
    FROM    public.payment          pmt
    INNER JOIN last_payment_date lpd    ON pmt.staff_id         = lpd.staff_id  AND
                                           pmt.payment_date     = lpd.last_payment_date
    GROUP BY pmt.staff_id
),
last_store AS (
    SELECT  lpm.staff_id,
            inv.store_id
    FROM    last_payment            lpm
    INNER JOIN public.payment       pmt     ON lpm.last_payment_id  = pmt.payment_id
    INNER JOIN public.rental        rnt     ON pmt.rental_id        = rnt.rental_id
    INNER JOIN public.inventory     inv     ON rnt.inventory_id     = inv.inventory_id
)
SELECT  stf.first_name,
        stf.last_name,
        lst.store_id        AS last_store_id,
        srv.revenue
FROM    staff_revenue       srv
INNER JOIN public.staff     stf     ON srv.staff_id = stf.staff_id
INNER JOIN last_store       lst     ON srv.staff_id = lst.staff_id
ORDER BY srv.revenue DESC,
        stf.last_name,
        stf.first_name,
        stf.staff_id
FETCH FIRST 3 ROWS ONLY;
 
-- 2.1 SUBQUERY solution
-- Derived table srv: revenue per employee in 2017.
-- Correlated subquery in SELECT: store of the employee's last 2017 payment.
-- The nested subqueries find that payment: first the latest payment time,
-- then the highest payment_id at that time.
SELECT  stf.first_name,
        stf.last_name,
        (
            SELECT  inv.store_id
            FROM    public.payment          pmt
            INNER JOIN public.rental        rnt     ON pmt.rental_id    = rnt.rental_id
            INNER JOIN public.inventory     inv     ON rnt.inventory_id = inv.inventory_id
            WHERE   pmt.payment_id = (
                        SELECT  MAX(pmt_last.payment_id)
                        FROM    public.payment pmt_last
                        WHERE   pmt_last.staff_id       = stf.staff_id  AND
                                pmt_last.payment_date   = (
                                    SELECT  MAX(pmt_date.payment_date)
                                    FROM    public.payment pmt_date
                                    WHERE   pmt_date.staff_id       =  stf.staff_id         AND
                                            pmt_date.payment_date   >= DATE '2017-01-01'    AND
                                            pmt_date.payment_date   <  DATE '2018-01-01'
                                )
                    )
        )                       AS last_store_id,
        srv.revenue
FROM    public.staff stf
INNER JOIN (
            SELECT  pmt.staff_id,
                    SUM(pmt.amount) AS revenue
            FROM    public.payment pmt
            WHERE   pmt.payment_date >= DATE '2017-01-01'   AND
                    pmt.payment_date <  DATE '2018-01-01'
            GROUP BY pmt.staff_id
        ) srv                       ON stf.staff_id = srv.staff_id
ORDER BY srv.revenue DESC,
        stf.last_name,
        stf.first_name,
        stf.staff_id
FETCH FIRST 3 ROWS ONLY;
 
-- 2.1 JOIN solution
-- One grouped query, no subqueries.
-- pmt: all 2017 payments of the employee - used for the revenue.
-- pmt_last + anti-join: pmt_last is the employee's LAST 2017 payment.
--   LEFT JOIN pmt_later looks for a later 2017 payment of the same employee
--   (later time, or the same time and a higher payment_id); WHERE
--   pmt_later.payment_id IS NULL keeps only the payment that has no later one.
--   That leaves exactly one pmt_last row per employee, so SUM(pmt.amount)
--   is not multiplied.
-- rnt_last/inv_last: store of that last payment.
-- INNER JOINs: every payment has a rental and every rental has an inventory
-- row, so no 2017 payment is lost.
SELECT  stf.first_name,
        stf.last_name,
        inv_last.store_id       AS last_store_id,
        SUM(pmt.amount)         AS revenue
FROM    public.staff                stf
INNER JOIN public.payment       pmt         ON stf.staff_id             = pmt.staff_id          AND
                                               pmt.payment_date         >= DATE '2017-01-01'    AND
                                               pmt.payment_date         <  DATE '2018-01-01'
INNER JOIN public.payment       pmt_last    ON stf.staff_id             = pmt_last.staff_id     AND
                                               pmt_last.payment_date    >= DATE '2017-01-01'    AND
                                               pmt_last.payment_date    <  DATE '2018-01-01'
LEFT JOIN public.payment        pmt_later   ON pmt_last.staff_id        = pmt_later.staff_id    AND
                                               pmt_later.payment_date   <  DATE '2018-01-01'    AND
                                               (pmt_later.payment_date  >  pmt_last.payment_date OR
                                                (pmt_later.payment_date = pmt_last.payment_date AND
                                                 pmt_later.payment_id   > pmt_last.payment_id))
INNER JOIN public.rental        rnt_last    ON pmt_last.rental_id       = rnt_last.rental_id
INNER JOIN public.inventory     inv_last    ON rnt_last.inventory_id    = inv_last.inventory_id
WHERE   pmt_later.payment_id IS NULL
GROUP BY stf.staff_id,
        stf.first_name,
        stf.last_name,
        inv_last.store_id
ORDER BY revenue DESC,
        stf.last_name,
        stf.first_name,
        stf.staff_id
FETCH FIRST 3 ROWS ONLY;
 
/*
    2.1 Comparison
    - CTE: each business rule (revenue, last payment time, last payment,
                last store) is a separate named step - easiest to read,
                explain and test. Reads the payment table several times.
    - SUBQUERY: revenue in a derived table, last store in a correlated
                subquery that runs once per employee (cheap here because there
                are few employees, slow if there were thousands). Three levels
                of nesting make it the hardest to read.
    - JOIN: no subqueries; the last payment is found with an anti-join
                (LEFT JOIN to a later payment + IS NULL). Correct and standard,
                but the anti-join compares each payment with the employee's
                later payments, which gets expensive for employees with many
                payments, and the double use of payment (pmt and pmt_last) is
                harder to follow.
    Production choice: CTE - correctness and readability matter more than
    reading a small table several times; each step can be checked separately.
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
    - Exactly 5 rows are returned (FETCH FIRST 5 ROWS ONLY). If films tie
      on number_of_rentals, title and then film_id decide the order.
---------------------------------------------------------------------------- */
 
-- 2.2 JOIN solution
-- INNER JOINs: only films that have been rented at least once (a film
-- without copies or rentals cannot be among the most rented).
SELECT  flm.title,
        flm.rating,
        CASE flm.rating::TEXT
            WHEN 'G'        THEN 'All ages'
            WHEN 'PG'       THEN 'All ages (parental guidance suggested)'
            WHEN 'PG-13'    THEN '13+'
            WHEN 'R'        THEN '17+ (under 17 with a parent or adult guardian)'
            WHEN 'NC-17'    THEN '18+'
            ELSE 'Not rated'
        END                         AS expected_audience_age,
        COUNT(rnt.rental_id)        AS number_of_rentals
FROM    public.film             flm
INNER JOIN public.inventory inv     ON flm.film_id      = inv.film_id
INNER JOIN public.rental        rnt     ON inv.inventory_id = rnt.inventory_id
GROUP BY flm.film_id,
        flm.title,
        flm.rating
ORDER BY number_of_rentals DESC,
        flm.title,
        flm.film_id
FETCH FIRST 5 ROWS ONLY;
 
-- 2.2 SUBQUERY solution
-- Derived table counts rentals per film_id; INNER JOIN with film adds the
-- title and rating.
SELECT  flm.title,
        flm.rating,
        CASE flm.rating::TEXT
            WHEN 'G'        THEN 'All ages'
            WHEN 'PG'       THEN 'All ages (parental guidance suggested)'
            WHEN 'PG-13'    THEN '13+'
            WHEN 'R'        THEN '17+ (under 17 with a parent or adult guardian)'
            WHEN 'NC-17'    THEN '18+'
            ELSE 'Not rated'
        END                         AS expected_audience_age,
        flmrnt.number_of_rentals
FROM    public.film flm
INNER JOIN (
            SELECT  inv.film_id,
                    COUNT(rnt.rental_id)    AS number_of_rentals
            FROM    public.rental           rnt
            INNER JOIN public.inventory inv     ON rnt.inventory_id = inv.inventory_id
            GROUP BY inv.film_id
        ) flmrnt                    ON flm.film_id = flmrnt.film_id
ORDER BY flmrnt.number_of_rentals DESC,
        flm.title,
        flm.film_id
FETCH FIRST 5 ROWS ONLY;
 
-- 2.2 CTE solution
WITH film_rentals AS (
    SELECT  inv.film_id,
            COUNT(rnt.rental_id)    AS number_of_rentals
    FROM    public.rental           rnt
    INNER JOIN public.inventory inv     ON rnt.inventory_id = inv.inventory_id
    GROUP BY inv.film_id
)
SELECT  flm.title,
        flm.rating,
        CASE flm.rating::TEXT
            WHEN 'G'        THEN 'All ages'
            WHEN 'PG'       THEN 'All ages (parental guidance suggested)'
            WHEN 'PG-13'    THEN '13+'
            WHEN 'R'        THEN '17+ (under 17 with a parent or adult guardian)'
            WHEN 'NC-17'    THEN '18+'
            ELSE 'Not rated'
        END                         AS expected_audience_age,
        frn.number_of_rentals
FROM    public.film         flm
INNER JOIN film_rentals frn     ON flm.film_id = frn.film_id
ORDER BY frn.number_of_rentals DESC,
        flm.title,
        flm.film_id
FETCH FIRST 5 ROWS ONLY;
 
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
    - gap_period = current year - latest release year.
---------------------------------------------------------------------------- */
 
-- 3 V1 JOIN solution
SELECT  act.first_name,
        act.last_name,
        MAX(flm.release_year)                                       AS latest_release_year,
        EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - MAX(flm.release_year)    AS gap_period
FROM    public.actor                act
INNER JOIN public.film_actor    flmact  ON act.actor_id     = flmact.actor_id
INNER JOIN public.film          flm     ON flmact.film_id   = flm.film_id
WHERE   flm.release_year IS NOT NULL
GROUP BY act.actor_id,
        act.first_name,
        act.last_name
ORDER BY gap_period DESC
FETCH FIRST 1 ROWS WITH TIES;
 
-- 3 V1 SUBQUERY solution
-- Derived table: latest release year per actor_id.
-- WHERE compares each actor's latest year with the minimum latest year of
-- all actors (= the longest gap), so ties are kept without FETCH.
SELECT  act.first_name,
        act.last_name,
        alr.latest_release_year,
        EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - alr.latest_release_year  AS gap_period
FROM    public.actor act
INNER JOIN (
            SELECT  flmact.actor_id,
                    MAX(flm.release_year)   AS latest_release_year
            FROM    public.film_actor   flmact
            INNER JOIN public.film  flm     ON flmact.film_id = flm.film_id
            WHERE   flm.release_year IS NOT NULL
            GROUP BY flmact.actor_id
        ) alr                       ON act.actor_id = alr.actor_id
WHERE   alr.latest_release_year = (
            SELECT  MIN(latest.latest_release_year)
            FROM    (
                        SELECT  MAX(flm.release_year)   AS latest_release_year
                        FROM    public.film_actor   flmact
                        INNER JOIN public.film  flm     ON flmact.film_id = flm.film_id
                        WHERE   flm.release_year IS NOT NULL
                        GROUP BY flmact.actor_id
                    ) latest
        )
ORDER BY act.last_name,
        act.first_name;
 
-- 3 V1 CTE solution
WITH actor_latest_release AS (
    SELECT  flmact.actor_id,
            MAX(flm.release_year)   AS latest_release_year
    FROM    public.film_actor   flmact
    INNER JOIN public.film  flm     ON flmact.film_id = flm.film_id
    WHERE   flm.release_year IS NOT NULL
    GROUP BY flmact.actor_id
)
SELECT  act.first_name,
        act.last_name,
        alr.latest_release_year,
        EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - alr.latest_release_year  AS gap_period
FROM    public.actor                act
INNER JOIN actor_latest_release alr     ON act.actor_id = alr.actor_id
WHERE   alr.latest_release_year = (
            SELECT  MIN(alr_all.latest_release_year)
            FROM    actor_latest_release alr_all
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
SELECT  act.first_name,
        act.last_name,
        flm.release_year                            AS gap_start_year,
        MIN(flm_next.release_year)                  AS gap_end_year,
        MIN(flm_next.release_year) - flm.release_year   AS gap_period
FROM    public.actor                act
INNER JOIN public.film_actor    flmact      ON act.actor_id         = flmact.actor_id
INNER JOIN public.film          flm         ON flmact.film_id       = flm.film_id
INNER JOIN public.film_actor    flmact_next ON act.actor_id         = flmact_next.actor_id
INNER JOIN public.film          flm_next    ON flmact_next.film_id  = flm_next.film_id
WHERE   flm_next.release_year > flm.release_year
GROUP BY act.actor_id,
        act.first_name,
        act.last_name,
        flm.release_year
ORDER BY gap_period DESC
FETCH FIRST 1 ROWS WITH TIES;
 
-- 3 V2 SUBQUERY solution
-- ayr: distinct (actor, release year) pairs.
-- The correlated subquery finds the next release year of the same actor.
-- The outer query keeps years that have a next year and returns the gap equal to the maximum gap.
SELECT  act.first_name,
        act.last_name,
        gps.gap_start_year,
        gps.gap_end_year,
        gps.gap_end_year - gps.gap_start_year   AS gap_period
FROM    public.actor act
INNER JOIN (
            SELECT  ayr.actor_id,
                    ayr.release_year        AS gap_start_year,
                    (
                        SELECT  MIN(flm_next.release_year)
                        FROM    public.film_actor   flmact_next
                        INNER JOIN public.film  flm_next    ON flmact_next.film_id = flm_next.film_id
                        WHERE   flmact_next.actor_id    = ayr.actor_id  AND
                                flm_next.release_year   > ayr.release_year
                    )                       AS gap_end_year
            FROM    (
                        SELECT  DISTINCT flmact.actor_id,
                                flm.release_year
                        FROM    public.film_actor   flmact
                        INNER JOIN public.film  flm     ON flmact.film_id = flm.film_id
                        WHERE   flm.release_year IS NOT NULL
                    ) ayr
        ) gps                       ON act.actor_id = gps.actor_id
WHERE   gps.gap_end_year IS NOT NULL
ORDER BY gap_period DESC
FETCH FIRST 1 ROWS WITH TIES;
 
-- 3 V2 CTE solution
-- actor_years: distinct (actor, release year) pairs.
-- actor_gaps: self-join of actor_years on actor_id; for each year the smallest later year (INNER JOIN: last years drop out).
-- max_gap: the longest gap of all actors.
WITH actor_years AS (
    SELECT  DISTINCT flmact.actor_id,
            flm.release_year
    FROM    public.film_actor   flmact
    INNER JOIN public.film  flm     ON flmact.film_id = flm.film_id
    WHERE   flm.release_year IS NOT NULL
),
actor_gaps AS (
    SELECT  ayr.actor_id,
            ayr.release_year                AS gap_start_year,
            MIN(ayr_next.release_year)      AS gap_end_year
    FROM    actor_years         ayr
    INNER JOIN actor_years  ayr_next    ON ayr.actor_id = ayr_next.actor_id
    WHERE   ayr_next.release_year > ayr.release_year
    GROUP BY ayr.actor_id,
            ayr.release_year
),
max_gap AS (
    SELECT  MAX(agp.gap_end_year - agp.gap_start_year)  AS max_gap_period
    FROM    actor_gaps agp
)
SELECT  act.first_name,
        act.last_name,
        agp.gap_start_year,
        agp.gap_end_year,
        agp.gap_end_year - agp.gap_start_year   AS gap_period
FROM    actor_gaps          agp
INNER JOIN public.actor act     ON agp.actor_id = act.actor_id
CROSS JOIN max_gap      mgp     -- one-row CTE: CROSS JOIN adds max_gap_period to every row
WHERE   agp.gap_end_year - agp.gap_start_year = mgp.max_gap_period
ORDER BY act.last_name,
        act.first_name;
 
/*
    3 V2 Comparison
    - JOIN: no helper steps, but joins every film of an actor with every
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