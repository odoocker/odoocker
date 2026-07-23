COPY public.res_partner (id, name, email, phone, mobile, vat, street, street2, zip) FROM stdin;
1	John Smith	john@example.com	555-1234	\N	US999	100 Real St	\N	02115
\.

COPY public.res_users (id, login, password, signature) FROM stdin;
1	admin@goldberrygrove.farm	$2b$12$realhashhere	<p>Sent from my iPhone</p>
\.

COPY public.mail_message (id, author_id, body, subject) FROM stdin;
10	1	<p>Customer asked about strawberry jam stock</p>	Stock inquiry
11	\N	<p>System notification</p>	Cron ran
\.

COPY public.mail_tracking_value (id, old_value_text, new_value_text) FROM stdin;
1	old confidential text	new confidential text
\.

COPY public.audittrail_log_line (id, old_value, new_value) FROM stdin;
1	prev	curr
\.

COPY public.payment_transaction (id, provider_reference, acquirer_reference) FROM stdin;
1	pi_stripe_real_xyz	stripe_xyz
\.

COPY public.product_template (id, name, list_price) FROM stdin;
100	Strawberry Jam	8.50
\.
