--
-- PostgreSQL database dump fragment for sanitizer testing
--

COPY public.res_partner (id, name, email, phone, mobile, vat, street, street2, zip) FROM stdin;
1	John Smith	john@example.com	555-1234	555-5678	US123456789	100 Real St	Apt 4	02115
2	Jane Doe	jane@goldberrygrove.farm	\N	555-9999	\N	200 Real Ave	\N	02116
3	Anonymous	\N	\N	\N	\N	\N	\N	\N
\.

COPY public.product_template (id, name, list_price) FROM stdin;
100	Strawberry Jam	8.50
101	Tomato Jam	9.00
\.
