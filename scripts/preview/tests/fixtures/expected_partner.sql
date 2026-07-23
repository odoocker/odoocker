--
-- PostgreSQL database dump fragment for sanitizer testing
--

COPY public.res_partner (id, name, email, phone, mobile, vat, street, street2, zip) FROM stdin;
1	Customer 1	pii-1@preview.local	\N	\N	\N	123 Preview Lane	\N	00000
2	Customer 2	pii-2@preview.local	\N	\N	\N	123 Preview Lane	\N	00000
3	Customer 3	pii-3@preview.local	\N	\N	\N	123 Preview Lane	\N	00000
\.

COPY public.product_template (id, name, list_price) FROM stdin;
100	Strawberry Jam	8.50
101	Tomato Jam	9.00
\.
