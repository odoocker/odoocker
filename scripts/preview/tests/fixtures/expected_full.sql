COPY public.res_partner (id, name, email, phone, mobile, vat, street, street2, zip) FROM stdin;
1	Customer 1	pii-1@preview.local	\N	\N	\N	123 Preview Lane	\N	00000
\.

COPY public.res_users (id, login, password, signature) FROM stdin;
1	user1@preview.local	$2b$12$aqLqsRzRYZlLYxlEFO6cJOEW9s84eiA/4IRSuQkw0ufC//2p.cTmi	\N
\.

COPY public.mail_message (id, author_id, body, subject) FROM stdin;
10	1	[REDACTED preview content]	[REDACTED]
11	\N	<p>System notification</p>	Cron ran
\.

COPY public.mail_tracking_value (id, old_value_text, new_value_text) FROM stdin;
1	\N	\N
\.

COPY public.audittrail_log_line (id, old_value, new_value) FROM stdin;
1	\N	\N
\.

COPY public.payment_transaction (id, provider_reference, acquirer_reference) FROM stdin;
1	\N	\N
\.

COPY public.product_template (id, name, list_price) FROM stdin;
100	Strawberry Jam	8.50
\.
