/*
		Why a separate transaction per subtask:
		Each subtask is one logical unit of work (for example "add films + their genres").
		Wrapping it in BEGIN ... COMMIT means it is saved completely or not at all,
		and a failure in one subtask does not undo the subtasks that were already committed.

	What happens if a transaction fails:
		PostgreSQL marks the transaction as aborted, every following statement in it is
		rejected, and nothing from that subtask is written. The script must then run
		ROLLBACK (DBeaver does it automatically when the transaction is closed), fix the
		cause and rerun the subtask.

	Is rollback possible and what data is affected:
		Until COMMIT, ROLLBACK undoes every change of the current subtask only. After
		COMMIT the change is permanent and can only be reverted by another DML statement.
		Sequence values (film_id, actor_id, ...) consumed by a rolled-back INSERT are not
		returned, so gaps in ids are possible. This is normal and harmless.

	How referential integrity is preserved:
		Foreign key values are never typed by hand. Every parent id is looked up by a
		natural key (film title + release year, actor name, language name, category name,
		customer email from the Settings block) in the same statement that inserts the child row, so a child row
		is inserted only if its parent exists. Parents are always inserted before children
		(film -> film_category / film_actor / inventory -> rental -> payment) and children
		are deleted before parents (payment -> rental).

	How duplicates are avoided (the script is rerunnable):
		Every INSERT is INSERT ... SELECT ... WHERE NOT EXISTS (natural key check).
		Where a primary key or unique index exists, ON CONFLICT DO NOTHING is added as a
		second safety net. Running the whole file again gives the same final state.

	Why INSERT INTO ... SELECT instead of INSERT INTO ... VALUES:
		1. Ids are resolved by the database from natural keys at run time, so nothing is
		   hardcoded and the script works on any copy of the database.
		2. The NOT EXISTS filter can be placed in the same statement, which makes the
		   insert idempotent.
		3. One statement inserts several rows and joins them to their parents, so a
		   missing parent gives zero inserted rows instead of a broken foreign key.

	last_update:
		All new and updated rows get last_update = current_date. Note: the tables have
		a BEFORE UPDATE trigger (last_updated) that overwrites last_update with the current
		timestamp on UPDATE, so updated rows show today's date with the time of the update.
		The payment table has no last_update column.
*/

/*
	Settings: my email, stored in one place
	The email is the natural key that identifies "me" as a customer in subtasks 1.4-1.6.
	It is saved once as a session setting and read with current_setting('hw.my_email')
	in every statement, so a change is made only here.
	Run this statement first (also when running single statements in DBeaver). If it was
	not run, every statement that uses the email stops with "unrecognized configuration
	parameter", so nothing can run with a missing email by mistake.
 */
SELECT	set_config('hw.my_email', 'aiym.abay@gmail.com', FALSE)	AS my_email;


/*
	Subtask 1.1 Add my top-3 favorite films and their genres
	- Avatar (James Cameron, not The Last Airbender)
						 2009  Sci-Fi  rental rate	4.99  rental duration 1 week (7 days)
	- Life of Pi		 2012  Family  rental rate	9.99  rental duration 2 weeks (14 days)
	- The Green Mile	 1999  Drama   rental rate 19.99  rental duration 3 weeks (21 days)

	Uniqueness: a film is identified by UPPER(title) + release_year. A film is inserted
	only if no film with the same title and year exists (WHERE NOT EXISTS).
	Relationships: language_id is looked up by language name 'English'. film_category
	gets film_id from the inserted film (by title + year) and category_id by category name.
	The fulltext column is filled by the film_fulltext_trigger. */
BEGIN;

INSERT INTO public.film (title, description, release_year, language_id, rental_duration,
						 rental_rate, length, replacement_cost, rating, last_update)
SELECT	new_film.title,
		new_film.description,
		new_film.release_year,
		lan.language_id,
		new_film.rental_duration,
		new_film.rental_rate,
		new_film.length,
		new_film.replacement_cost,
		new_film.rating::public.mpaa_rating,
		current_date
FROM	(VALUES
			('AVATAR',
			 'A paralysed former marine controls an alien body on the moon Pandora and has to choose between his own people and the native Na''vi',
			 2009, 7, 4.99, 162, 24.99, 'PG-13'),
			('LIFE OF PI',
			 'After a shipwreck an Indian teenager survives for months in a lifeboat in the Pacific Ocean together with a Bengal tiger',
			 2012, 14, 9.99, 127, 22.99, 'PG'),
			('THE GREEN MILE',
			 'A death row prison guard discovers that a gentle inmate convicted of murder has a mysterious gift of healing',
			 1999, 21, 19.99, 189, 21.99, 'R')
		) AS new_film (title, description, release_year, rental_duration, rental_rate, length, replacement_cost, rating)
CROSS JOIN public.language lan
WHERE	UPPER(TRIM(lan.name)) = 'ENGLISH' AND
		NOT EXISTS (SELECT	1
					FROM	public.film fil
					WHERE	UPPER(fil.title) = UPPER(new_film.title) AND
							fil.release_year = new_film.release_year)
RETURNING film_id, title, release_year, rental_rate, rental_duration, last_update;

--Genres: one category per film, matched by category name
INSERT INTO public.film_category (film_id, category_id, last_update)
SELECT	fil.film_id,
		cat.category_id,
		current_date
FROM	(VALUES
			('AVATAR',			2009, 'SCI-FI'),
			('LIFE OF PI',		2012, 'FAMILY'),
			('THE GREEN MILE',	1999, 'DRAMA')
		) AS new_genre (title, release_year, category_name)
INNER JOIN public.film		fil ON UPPER(fil.title) = new_genre.title AND fil.release_year = new_genre.release_year
INNER JOIN public.category	cat ON UPPER(cat.name)	= new_genre.category_name
WHERE	NOT EXISTS (SELECT	1
					FROM	public.film_category filcat
					WHERE	filcat.film_id = fil.film_id AND
							filcat.category_id = cat.category_id)
ON CONFLICT (film_id, category_id) DO NOTHING
RETURNING film_id, category_id, last_update;

--Check before commit: 3 films, each with its genre
SELECT	fil.film_id,
		fil.title,
		fil.release_year,
		fil.rental_rate,
		fil.rental_duration,
		cat.name	AS category_name
FROM	public.film fil
INNER JOIN public.film_category filcat	ON filcat.film_id = fil.film_id
INNER JOIN public.category		cat		ON cat.category_id = filcat.category_id
WHERE	UPPER(fil.title) IN ('AVATAR', 'LIFE OF PI', 'THE GREEN MILE')
ORDER BY fil.release_year;

COMMIT;


/*
	Subtask 1.2 Add the leading actors to actor and film_actor (7 actors)

	Uniqueness: the actor table has no natural unique key, so an actor is identified
	by UPPER(first_name) + UPPER(last_name). If an actor with the same name already
	exists, the existing row is reused and no new row is inserted (WHERE NOT EXISTS).
	Names are stored in upper case like the existing rows of the table.
	Relationships: film_actor gets actor_id by actor name and film_id by title + year,
	both resolved in the same statement. The (actor_id, film_id) primary key plus
	WHERE NOT EXISTS / ON CONFLICT DO NOTHING prevent duplicate links.
*/
BEGIN;

INSERT INTO public.actor (first_name, last_name, last_update)
SELECT	new_actor.first_name,
		new_actor.last_name,
		current_date
FROM	(VALUES
			('SAM',		  'WORTHINGTON'),
			('ZOE',		  'SALDANA'),
			('SIGOURNEY', 'WEAVER'),
			('SURAJ',	  'SHARMA'),
			('IRRFAN',	  'KHAN'),
			('TOM',		  'HANKS'),
			('MICHAEL',	  'CLARKE DUNCAN')
		) AS new_actor (first_name, last_name)
WHERE	NOT EXISTS (SELECT	1
					FROM	public.actor act
					WHERE	UPPER(act.first_name) = new_actor.first_name AND
							UPPER(act.last_name)  = new_actor.last_name)
RETURNING actor_id, first_name, last_name, last_update;

INSERT INTO public.film_actor (actor_id, film_id, last_update)
SELECT	act.actor_id,
		fil.film_id,
		current_date
FROM	(VALUES
			('SAM',		  'WORTHINGTON',   'AVATAR',		 2009),
			('ZOE',		  'SALDANA',	   'AVATAR',		 2009),
			('SIGOURNEY', 'WEAVER',		   'AVATAR',		 2009),
			('SURAJ',	  'SHARMA',		   'LIFE OF PI',	 2012),
			('IRRFAN',	  'KHAN',		   'LIFE OF PI',	 2012),
			('TOM',		  'HANKS',		   'THE GREEN MILE', 1999),
			('MICHAEL',	  'CLARKE DUNCAN', 'THE GREEN MILE', 1999)
		) AS new_role (first_name, last_name, title, release_year)
INNER JOIN public.actor act ON UPPER(act.first_name) = new_role.first_name AND UPPER(act.last_name) = new_role.last_name
INNER JOIN public.film	fil ON UPPER(fil.title) = new_role.title AND fil.release_year = new_role.release_year
WHERE	NOT EXISTS (SELECT	1
					FROM	public.film_actor filact
					WHERE	filact.actor_id = act.actor_id AND
							filact.film_id = fil.film_id)
ON CONFLICT (actor_id, film_id) DO NOTHING
RETURNING actor_id, film_id, last_update;

--Check before commit: 7 actor-film links
SELECT	fil.title,
		act.first_name,
		act.last_name
FROM	public.film_actor filact
INNER JOIN public.actor act ON act.actor_id = filact.actor_id
INNER JOIN public.film	fil ON fil.film_id = filact.film_id
WHERE	UPPER(fil.title) IN ('AVATAR', 'LIFE OF PI', 'THE GREEN MILE')
ORDER BY fil.title, act.last_name;

COMMIT;


/*
	Subtask 1.3 Add my films to a store's inventory

	Store choice: the store with the lowest store_id (resolved by a query, not typed).
	Uniqueness: one copy per film per store. A copy is added only if this film is not
	in this store's inventory yet (WHERE NOT EXISTS on film_id + store_id).
	Relationships: film_id comes from the film table by title + year, store_id from the
	store table, so both foreign keys point to existing rows.
*/
BEGIN;

INSERT INTO public.inventory (film_id, store_id, last_update)
SELECT	fil.film_id,
		sto.store_id,
		current_date
FROM	public.film fil
CROSS JOIN (SELECT	str.store_id
			FROM	public.store str
			ORDER BY str.store_id
			LIMIT 1) AS sto
WHERE	(UPPER(fil.title), fil.release_year) IN (('AVATAR', 2009), ('LIFE OF PI', 2012), ('THE GREEN MILE', 1999)) AND
		NOT EXISTS (SELECT	1
					FROM	public.inventory inv
					WHERE	inv.film_id = fil.film_id AND
							inv.store_id = sto.store_id)
RETURNING inventory_id, film_id, store_id, last_update;

--Check before commit: one inventory row per film
SELECT	inv.inventory_id,
		inv.store_id,
		fil.title
FROM	public.inventory inv
INNER JOIN public.film fil ON fil.film_id = inv.film_id
WHERE	UPPER(fil.title) IN ('AVATAR', 'LIFE OF PI', 'THE GREEN MILE');

COMMIT;


/*
	Subtask 1.4 Turn an existing customer (at least 43 rentals and 43 payments) into me

	Which customer is updated:
		- if a customer that is already me exists (the script was run before), that customer
		  is updated again, so a rerun never changes a second customer. "Me" is found by my
		  email OR by my name AIYM ABAY, so a rerun after the email was changed still finds
		  the same customer instead of taking a new one;
		- otherwise the qualifying customer with the lowest customer_id is taken
		  (deterministic choice, no hardcoded id).
	Address: an existing address in Pavlodar, Kazakhstan (lowest address_id there) is
	referenced. The address table itself is not updated, because one address row can be
	shared by several customers. There is no fallback to the old address: if no Pavlodar
	address is found, address_id becomes NULL, the NOT NULL constraint stops the UPDATE
	and the transaction fails instead of silently keeping the old address.
	The same target_customer logic is used in the check SELECT and in the UPDATE.
*/
BEGIN;

--Check before update: only the customer that will be changed, with its counts and new address
WITH my_existing_customer AS (
	SELECT	cus.customer_id
	FROM	public.customer cus
	WHERE	UPPER(cus.email) = UPPER(current_setting('hw.my_email')) OR
			(UPPER(cus.first_name) = 'AIYM' AND UPPER(cus.last_name) = 'ABAY')
	ORDER BY cus.customer_id
	LIMIT 1
),
rental_counts AS (
	SELECT	ren.customer_id,
			COUNT(*)	AS rental_count
	FROM	public.rental ren
	GROUP BY ren.customer_id
),
payment_counts AS (
	SELECT	pay.customer_id,
			COUNT(*)	AS payment_count
	FROM	public.payment pay
	GROUP BY pay.customer_id
),
qualifying_customer AS (
	SELECT	renc.customer_id
	FROM	rental_counts renc
	INNER JOIN payment_counts payc ON payc.customer_id = renc.customer_id
	WHERE	renc.rental_count >= 43 AND
			payc.payment_count >= 43 AND
			NOT EXISTS (SELECT 1 FROM my_existing_customer)
	ORDER BY renc.customer_id
	LIMIT 1
),
target_customer AS (
	SELECT customer_id FROM my_existing_customer
	UNION ALL
	SELECT customer_id FROM qualifying_customer
),
my_address AS (
	SELECT	adr.address_id,
			adr.address,
			cit.city
	FROM	public.address adr
	INNER JOIN public.city		cit ON cit.city_id = adr.city_id
	INNER JOIN public.country	cou ON cou.country_id = cit.country_id
	WHERE	UPPER(cit.city) = 'PAVLODAR' AND
			UPPER(cou.country) LIKE 'KAZAK%'
	ORDER BY adr.address_id
	LIMIT 1
)
SELECT	cus.customer_id,
		cus.first_name,
		cus.last_name,
		cus.email,
		COALESCE(renc.rental_count, 0)	AS rental_count,
		COALESCE(payc.payment_count, 0) AS payment_count,
		cus.address_id					AS old_address_id,
		myadr.address_id				AS new_address_id,
		myadr.city						AS new_city
FROM	target_customer tgt
INNER JOIN public.customer cus ON cus.customer_id = tgt.customer_id
LEFT OUTER JOIN rental_counts	renc ON renc.customer_id = cus.customer_id
LEFT OUTER JOIN payment_counts	payc ON payc.customer_id = cus.customer_id
LEFT OUTER JOIN my_address		myadr ON TRUE;
--Expected: exactly 1 row, new_city = Pavlodar

WITH my_existing_customer AS (
	SELECT	cus.customer_id
	FROM	public.customer cus
	WHERE	UPPER(cus.email) = UPPER(current_setting('hw.my_email')) OR
			(UPPER(cus.first_name) = 'AIYM' AND UPPER(cus.last_name) = 'ABAY')
	ORDER BY cus.customer_id
	LIMIT 1
),
rental_counts AS (
	SELECT	ren.customer_id,
			COUNT(*)	AS rental_count
	FROM	public.rental ren
	GROUP BY ren.customer_id
),
payment_counts AS (
	SELECT	pay.customer_id,
			COUNT(*)	AS payment_count
	FROM	public.payment pay
	GROUP BY pay.customer_id
),
qualifying_customer AS (
	SELECT	renc.customer_id
	FROM	rental_counts renc
	INNER JOIN payment_counts payc ON payc.customer_id = renc.customer_id
	WHERE	renc.rental_count >= 43 AND
			payc.payment_count >= 43 AND
			NOT EXISTS (SELECT 1 FROM my_existing_customer)
	ORDER BY renc.customer_id
	LIMIT 1
),
target_customer AS (
	SELECT customer_id FROM my_existing_customer
	UNION ALL
	SELECT customer_id FROM qualifying_customer
),
my_address AS (
	SELECT	adr.address_id
	FROM	public.address adr
	INNER JOIN public.city		cit ON cit.city_id = adr.city_id
	INNER JOIN public.country	cou ON cou.country_id = cit.country_id
	WHERE	UPPER(cit.city) = 'PAVLODAR' AND
			UPPER(cou.country) LIKE 'KAZAK%'
	ORDER BY adr.address_id
	LIMIT 1
)
UPDATE	public.customer cus
SET		first_name	= 'AIYM',
		last_name	= 'ABAY',
		email		= current_setting('hw.my_email'),
		address_id	= (SELECT address_id FROM my_address),
		activebool	= TRUE,
		active		= 1,
		last_update = current_date
FROM	target_customer tgt
WHERE	cus.customer_id = tgt.customer_id
RETURNING cus.customer_id, cus.store_id, cus.first_name, cus.last_name, cus.email, cus.address_id, cus.last_update;

--Check after update, before commit: exactly one customer has my data and lives in Pavlodar.
--address_check must be 'OK' and customer_count must be 1; otherwise run ROLLBACK instead of COMMIT.
SELECT	cus.customer_id,
		cus.first_name,
		cus.last_name,
		cus.email,
		adr.address,
		cit.city,
		COUNT(*) OVER ()	AS customer_count,
		CASE
			WHEN UPPER(cit.city) = 'PAVLODAR' THEN 'OK'
			ELSE 'ERROR: address was not changed'
		END					AS address_check
FROM	public.customer cus
INNER JOIN public.address	adr ON adr.address_id = cus.address_id
INNER JOIN public.city		cit ON cit.city_id = adr.city_id
WHERE	UPPER(cus.email) = UPPER(current_setting('hw.my_email'));

COMMIT;


/*
	Subtask 1.5 Remove all records related to me, except customer and inventory

	Tables that reference the customer: rental and payment (payment also references
	rental). Inventory does not reference the customer, so it is not touched.
	Order: payment first, then rental, because payment.rental_id is a foreign key to
	rental. Deleting from the partitioned parent table public.payment removes rows from
	all its partitions.

	Why it is safe:
		- rows are filtered only by my customer_id, found by my unique email;
		- payments are deleted if they belong to me OR point to one of my rentals, so no
		  payment row of any customer is left referencing a deleted rental;
		- no other table references rental or payment, so nothing else is orphaned;
		- the customer row itself stays, so customer_id stays valid.
	How unintended data loss is avoided:
		- a SELECT before the DELETE shows how many rows will go;
		- RETURNING lists every deleted row;
		- a SELECT after the DELETE confirms 0 rows are left, before COMMIT. If the
		  numbers do not match the preview, run ROLLBACK instead of COMMIT.
	Rerun note: on a second run this subtask also deletes the rentals/payments created in
	subtask 1.6, and 1.6 creates them again, so the final state is the same.
*/
BEGIN;

--Check before delete: how many rows will be removed
SELECT	'rental'	AS table_name,
		COUNT(*)	AS row_count
FROM	public.rental ren
INNER JOIN public.customer cus ON cus.customer_id = ren.customer_id
WHERE	UPPER(cus.email) = UPPER(current_setting('hw.my_email'))
UNION ALL
SELECT	'payment'	AS table_name,
		COUNT(*)	AS row_count
FROM	public.payment pay
INNER JOIN public.customer cus ON cus.customer_id = pay.customer_id
WHERE	UPPER(cus.email) = UPPER(current_setting('hw.my_email'));

DELETE FROM public.payment pay
WHERE	pay.customer_id IN (SELECT	cus.customer_id
							FROM	public.customer cus
							WHERE	UPPER(cus.email) = UPPER(current_setting('hw.my_email'))) OR
		pay.rental_id IN (SELECT	ren.rental_id
						  FROM		public.rental ren
						  INNER JOIN public.customer cus ON cus.customer_id = ren.customer_id
						  WHERE		UPPER(cus.email) = UPPER(current_setting('hw.my_email')))
RETURNING pay.payment_id, pay.customer_id, pay.rental_id, pay.amount;

DELETE FROM public.rental ren
WHERE	ren.customer_id IN (SELECT	cus.customer_id
							FROM	public.customer cus
							WHERE	UPPER(cus.email) = UPPER(current_setting('hw.my_email')))
RETURNING ren.rental_id, ren.customer_id, ren.inventory_id;

--Check after delete, before commit: both counts must be 0
SELECT	(SELECT COUNT(*)
		 FROM	public.rental ren
		 INNER JOIN public.customer cus ON cus.customer_id = ren.customer_id
		 WHERE	UPPER(cus.email) = UPPER(current_setting('hw.my_email')))	AS rental_count_left,
		(SELECT COUNT(*)
		 FROM	public.payment pay
		 INNER JOIN public.customer cus ON cus.customer_id = pay.customer_id
		 WHERE	UPPER(cus.email) = UPPER(current_setting('hw.my_email')))	AS payment_count_left;

COMMIT;


/*
	Subtask 1.6 Rent my favorite films from their store and pay for them

	Dates: the payment table is partitioned by payment_date and only has partitions for
	the first half of 2017, so rentals and payments are dated June 2017.
	Staff: the staff member with the lowest staff_id working in the store that holds the
	copy, so the film is rented from the store it is in.

	Payment rules (my assumption, the database has no fee rules of its own):
		- the payment is made when the film is returned, so payment_date = return_date;
		- returned on time (days kept <= rental_duration): amount = rental_rate;
		- returned late: amount = rental_rate + 1.00 for each day over rental_duration;
		- kept more than twice the rental_duration: treated as lost, amount =
		  rental_rate + replacement_cost.
	To show the late-fee branch, LIFE OF PI is kept 17 days with a 14-day duration
	(3 days late: 9.99 + 3.00 = 12.99). AVATAR and THE GREEN MILE are returned on time.

	Uniqueness:
		- rental: not inserted if a rental of the same copy by me on the same date
		  exists (this is also the unique index rental_date + inventory_id + customer_id);
		- payment: not inserted if a payment for this rental already exists.
	Relationships: inventory_id from the inventory of my films, customer_id by my email,
	staff_id from the staff of the inventory's store; payment takes rental_id,
	customer_id and staff_id from the rental it pays for.
*/
BEGIN;

INSERT INTO public.rental (rental_date, inventory_id, customer_id, return_date, staff_id, last_update)
SELECT	new_rental.rental_date,
		film_copy.inventory_id,
		cus.customer_id,
		new_rental.rental_date + new_rental.days_kept * INTERVAL '1 day',
		stf.staff_id,
		current_date
FROM	(VALUES
			('AVATAR',			2009, TIMESTAMPTZ '2017-06-01 12:00:00',  7),	-- on time
			('LIFE OF PI',		2012, TIMESTAMPTZ '2017-06-02 12:00:00', 17),	-- 3 days late
			('THE GREEN MILE',	1999, TIMESTAMPTZ '2017-06-03 12:00:00', 21)	-- on time
		) AS new_rental (title, release_year, rental_date, days_kept)
INNER JOIN public.film fil ON UPPER(fil.title) = new_rental.title AND fil.release_year = new_rental.release_year
INNER JOIN LATERAL (SELECT	inv.inventory_id,
							inv.store_id
					FROM	public.inventory inv
					WHERE	inv.film_id = fil.film_id
					ORDER BY inv.inventory_id
					LIMIT 1) AS film_copy ON TRUE
INNER JOIN LATERAL (SELECT	sta.staff_id
					FROM	public.staff sta
					WHERE	sta.store_id = film_copy.store_id
					ORDER BY sta.staff_id
					LIMIT 1) AS stf ON TRUE
CROSS JOIN public.customer cus
WHERE	UPPER(cus.email) = UPPER(current_setting('hw.my_email')) AND
		NOT EXISTS (SELECT	1
					FROM	public.rental ren
					WHERE	ren.inventory_id = film_copy.inventory_id AND
							ren.customer_id = cus.customer_id AND
							ren.rental_date = new_rental.rental_date)
ON CONFLICT (rental_date, inventory_id, customer_id) DO NOTHING
RETURNING rental_id, rental_date, inventory_id, customer_id, return_date, staff_id, last_update;

INSERT INTO public.payment (customer_id, staff_id, rental_id, amount, payment_date)
SELECT	ren_days.customer_id,
		ren_days.staff_id,
		ren_days.rental_id,
		ren_days.rental_rate +
		CASE
			WHEN ren_days.days_kept > 2 * ren_days.rental_duration THEN ren_days.replacement_cost
			WHEN ren_days.days_kept > ren_days.rental_duration THEN (ren_days.days_kept - ren_days.rental_duration) * 1.00
			ELSE 0
		END					AS amount,
		ren_days.return_date
FROM	(SELECT	ren.rental_id,
				ren.customer_id,
				ren.staff_id,
				ren.return_date,
				fil.rental_rate,
				fil.rental_duration,
				fil.replacement_cost,
				EXTRACT(DAY FROM ren.return_date - ren.rental_date)::int	AS days_kept
		 FROM	public.rental ren
		 INNER JOIN public.customer		cus ON cus.customer_id = ren.customer_id
		 INNER JOIN public.inventory	inv ON inv.inventory_id = ren.inventory_id
		 INNER JOIN public.film			fil ON fil.film_id = inv.film_id
		 WHERE	UPPER(cus.email) = UPPER(current_setting('hw.my_email')) AND
				UPPER(fil.title) IN ('AVATAR', 'LIFE OF PI', 'THE GREEN MILE') AND
				ren.return_date IS NOT NULL
		) AS ren_days
WHERE	NOT EXISTS (SELECT	1
					FROM	public.payment pay
					WHERE	pay.rental_id = ren_days.rental_id)
RETURNING payment_id, customer_id, staff_id, rental_id, amount, payment_date;

--Check before commit: 3 rentals, each paid once; LIFE OF PI shows 3 late days and 12.99
SELECT	fil.title,
		ren.rental_id,
		ren.rental_date,
		ren.return_date,
		fil.rental_duration,
		EXTRACT(DAY FROM ren.return_date - ren.rental_date)::int	AS days_kept,
		fil.rental_rate,
		pay.payment_id,
		pay.amount,
		pay.payment_date
FROM	public.rental ren
INNER JOIN public.customer	cus ON cus.customer_id = ren.customer_id
INNER JOIN public.inventory inv ON inv.inventory_id = ren.inventory_id
INNER JOIN public.film		fil ON fil.film_id = inv.film_id
LEFT OUTER JOIN public.payment pay ON pay.rental_id = ren.rental_id
WHERE	UPPER(cus.email) = UPPER(current_setting('hw.my_email'))
ORDER BY ren.rental_date;

COMMIT;
