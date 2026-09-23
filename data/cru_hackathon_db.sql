-- =====================================================================
-- CRU Review Assistant - Base de datos sintética (SQLite)
-- Hackathon TCS x USAA - Property & Casualty
--
-- TODOS LOS DATOS SON FICTICIOS. Nombres, números de póliza, VINs y
-- llamadas son inventados. Estructura de coberturas basada en info
-- pública de USAA auto; los niveles de rental reimbursement y su
-- clase de vehículo son supuestos para la demo (confirmar con Victoria).
--
-- Uso:  sqlite3 cru.db < cru_hackathon_db.sql
-- =====================================================================

PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------------
-- 1. CATÁLOGOS
-- ---------------------------------------------------------------------

-- Tipos de cobertura (nombres como aparecen en una póliza auto USAA)
CREATE TABLE catalogo_coberturas (
    codigo          TEXT PRIMARY KEY,
    nombre          TEXT NOT NULL,
    nivel           TEXT NOT NULL CHECK (nivel IN ('POLIZA','VEHICULO')),
    opcional        INTEGER NOT NULL,          -- 1 = endoso/add-on
    requiere        TEXT,                      -- coberturas prerequisito
    nombre_alterno  TEXT,                      -- nombre en algunos estados
    descripcion     TEXT
);

INSERT INTO catalogo_coberturas VALUES
('BI',      'Bodily Injury Liability',          'POLIZA',   0, NULL, NULL, 'Lesiones a terceros cuando el miembro es responsable'),
('PD',      'Property Damage Liability',        'POLIZA',   0, NULL, NULL, 'Daños a propiedad de terceros'),
('UMUIM',   'Uninsured/Underinsured Motorist',  'POLIZA',   0, NULL, NULL, 'Lesiones causadas por conductor sin seguro o con seguro insuficiente'),
('PIP',     'Personal Injury Protection',       'POLIZA',   0, NULL, NULL, 'Gastos médicos y salarios perdidos, sin importar culpa'),
('MEDPAY',  'Medical Payments',                 'POLIZA',   1, NULL, NULL, 'Gastos médicos de conductor y pasajeros'),
('COMP',    'Comprehensive',                    'VEHICULO', 0, NULL, NULL, 'Robo, granizo, inundación, vandalismo, animales'),
('COLL',    'Collision',                        'VEHICULO', 0, NULL, NULL, 'Daños al vehículo por choque'),
('RENTAL',  'Rental Reimbursement',             'VEHICULO', 1, 'COMP,COLL', 'Transportation Expense',
            'Paga auto de renta mientras el vehículo se repara tras una pérdida cubierta; no aplica a mantenimiento'),
('ROADSIDE','Roadside Assistance',              'VEHICULO', 1, NULL, NULL, 'Grúa, paso de corriente, gasolina, llanta, cerrajería'),
('CRA',     'Car Replacement Assistance',       'VEHICULO', 1, 'COMP,COLL', NULL, 'Paga 20% extra sobre el valor real si el auto es pérdida total'),
('AF',      'Accident Forgiveness',             'POLIZA',   1, NULL, NULL, 'La prima no sube por el primer accidente con culpa'),
('RSG',     'Rideshare Gap Protection',         'VEHICULO', 1, NULL, NULL, 'Cubre mientras el conductor espera viaje en app de rideshare');

-- Niveles de Rental Reimbursement (SUPUESTO para la demo)
-- El límite diario determina qué clase de auto de renta queda cubierta.
CREATE TABLE niveles_renta (
    codigo            TEXT PRIMARY KEY,
    limite_diario     INTEGER NOT NULL,   -- USD por día
    maximo_por_evento INTEGER NOT NULL,   -- USD por reclamo
    dias_maximos      INTEGER NOT NULL,
    clase_vehiculo    TEXT NOT NULL,      -- clase de renta cubierta
    ejemplos          TEXT NOT NULL,
    exclusiones       TEXT NOT NULL
);

INSERT INTO niveles_renta VALUES
('R30', 30,  900, 30, 'Economy / Compact',          'Nissan Versa, Kia Rio, Mitsubishi Mirage',
       'Lujo, exóticos, camiones de mudanza; no cubre mantenimiento de rutina'),
('R40', 40, 1200, 30, 'Intermediate / Standard',    'Toyota Corolla, Hyundai Elantra, VW Jetta',
       'Lujo, exóticos, camiones de mudanza; no cubre mantenimiento de rutina'),
('R50', 50, 1500, 30, 'Full-size sedan / Small SUV','Toyota Camry, Chevrolet Malibu, Nissan Rogue',
       'Lujo, exóticos, camiones de mudanza; no cubre mantenimiento de rutina'),
('R60', 60, 1800, 30, 'Mid-size SUV / Minivan / Pickup','Toyota RAV4, Chrysler Pacifica, Chevrolet Colorado',
       'Lujo, exóticos, camiones de mudanza; no cubre mantenimiento de rutina');

-- ---------------------------------------------------------------------
-- 2. PÓLIZA
-- ---------------------------------------------------------------------

CREATE TABLE miembros (
    id               INTEGER PRIMARY KEY,
    numero_miembro   TEXT UNIQUE NOT NULL,
    nombre           TEXT NOT NULL,
    elegibilidad     TEXT NOT NULL,       -- Active duty, Veteran, Spouse...
    rama             TEXT,
    estado           TEXT NOT NULL,       -- estado de EE.UU.
    ciudad           TEXT NOT NULL
);

INSERT INTO miembros VALUES
(1, '00-4471-982', 'Daniel R. Ortiz', 'Active Duty', 'U.S. Army', 'TX', 'San Antonio'),
(2, '00-5528-310', 'Megan L. Brooks', 'Veteran',     'U.S. Navy', 'VA', 'Norfolk');

CREATE TABLE polizas (
    id              INTEGER PRIMARY KEY,
    numero_poliza   TEXT UNIQUE NOT NULL,
    miembro_id      INTEGER NOT NULL REFERENCES miembros(id),
    linea           TEXT NOT NULL DEFAULT 'AUTO',
    estado_emision  TEXT NOT NULL,
    fecha_inicio    DATE NOT NULL,
    duracion_meses  INTEGER NOT NULL DEFAULT 6,
    estatus         TEXT NOT NULL DEFAULT 'ACTIVA'
);

INSERT INTO polizas VALUES
(1, 'AUT-4471982-7101', 1, 'AUTO', 'TX', '2022-01-15', 6, 'ACTIVA'),
(2, 'AUT-5528310-7102', 2, 'AUTO', 'VA', '2023-06-01', 6, 'ACTIVA');

-- Periodos de 6 meses (los "20+ policy terms" del formulario)
CREATE TABLE periodos (
    id           INTEGER PRIMARY KEY,
    poliza_id    INTEGER NOT NULL REFERENCES polizas(id),
    numero       INTEGER NOT NULL,
    fecha_inicio DATE NOT NULL,
    fecha_fin    DATE NOT NULL,
    UNIQUE (poliza_id, numero)
);

-- Genera periodos semestrales hasta 2027
INSERT INTO periodos (poliza_id, numero, fecha_inicio, fecha_fin)
WITH RECURSIVE t(poliza_id, numero, ini) AS (
    SELECT id, 1, fecha_inicio FROM polizas
    UNION ALL
    SELECT poliza_id, numero + 1, date(ini, '+6 months')
    FROM t WHERE date(ini, '+6 months') < '2027-01-01'
)
SELECT poliza_id, numero, ini, date(ini, '+6 months') FROM t;

CREATE TABLE conductores (
    id          INTEGER PRIMARY KEY,
    poliza_id   INTEGER NOT NULL REFERENCES polizas(id),
    nombre      TEXT NOT NULL,
    relacion    TEXT NOT NULL,
    alta        DATE NOT NULL,
    baja        DATE
);

INSERT INTO conductores VALUES
(1, 1, 'Daniel R. Ortiz', 'Titular',  '2022-01-15', NULL),
(2, 1, 'Ana P. Ortiz',    'Cónyuge',  '2022-01-15', NULL),
(3, 2, 'Megan L. Brooks', 'Titular',  '2023-06-01', NULL);

CREATE TABLE vehiculos (
    id          INTEGER PRIMARY KEY,
    poliza_id   INTEGER NOT NULL REFERENCES polizas(id),
    anio        INTEGER NOT NULL,
    marca       TEXT NOT NULL,
    modelo      TEXT NOT NULL,
    tipo        TEXT NOT NULL,          -- Sedan, SUV, Pickup, Minivan
    vin         TEXT NOT NULL,          -- VIN ficticio
    uso         TEXT NOT NULL,          -- Commute, Pleasure, Business
    financiado  TEXT,                   -- Lienholder / NULL
    alta        DATE NOT NULL,
    baja        DATE
);

INSERT INTO vehiculos VALUES
(1, 1, 2019, 'Ford',     'F-150 XLT',     'Pickup',  '1FTEW1E50KFX00001', 'Commute',  NULL,                 '2022-01-15', '2024-05-02'),
(2, 1, 2021, 'Honda',    'CR-V EX',       'SUV',     '2HKRW2H59MHX00002', 'Pleasure', 'USAA Federal Savings','2022-01-15', NULL),
(3, 1, 2024, 'Toyota',   'Tacoma TRD',    'Pickup',  '3TMLB5JN1RMX00003', 'Commute',  'Toyota Financial',   '2024-05-02', NULL),
(4, 2, 2022, 'Chrysler', 'Pacifica Touring','Minivan','2C4RC1BG8NRX00004','Pleasure', NULL,                 '2023-06-01', NULL);

-- ---------------------------------------------------------------------
-- 3. COBERTURAS (estado vigente por rango de fechas)
--    Cada cambio cierra la fila anterior (vigente_hasta) y abre una nueva.
-- ---------------------------------------------------------------------

CREATE TABLE coberturas (
    id              INTEGER PRIMARY KEY,
    poliza_id       INTEGER NOT NULL REFERENCES polizas(id),
    vehiculo_id     INTEGER REFERENCES vehiculos(id),   -- NULL = nivel póliza
    codigo          TEXT NOT NULL REFERENCES catalogo_coberturas(codigo),
    limite          TEXT,          -- ej. '100/300', '$100,000'
    deducible       INTEGER,
    nivel_renta     TEXT REFERENCES niveles_renta(codigo),
    detalles        TEXT,          -- JSON con atributos propios de la cobertura
    vigente_desde   DATE NOT NULL,
    vigente_hasta   DATE           -- NULL = vigente hoy
);

INSERT INTO coberturas (poliza_id, vehiculo_id, codigo, limite, deducible, nivel_renta, detalles, vigente_desde, vigente_hasta) VALUES
-- Póliza 1 (TX) - nivel póliza
(1, NULL, 'BI',    '$100,000/$300,000', NULL, NULL, '{"por_persona":100000,"por_accidente":300000}', '2022-01-15', NULL),
(1, NULL, 'PD',    '$100,000',          NULL, NULL, NULL, '2022-01-15', NULL),
(1, NULL, 'UMUIM', '$100,000/$300,000', NULL, NULL, NULL, '2022-01-15', NULL),
(1, NULL, 'PIP',   '$2,500',            NULL, NULL, NULL, '2022-01-15', NULL),
-- F-150 (dado de baja 2024-05-02)
(1, 1, 'COMP',     NULL, 500, NULL, NULL, '2022-01-15', '2024-05-02'),
(1, 1, 'COLL',     NULL, 500, NULL, NULL, '2022-01-15', '2024-05-02'),
(1, 1, 'ROADSIDE', NULL, NULL, NULL, '{"remolque_millas":15}', '2022-01-15', '2024-05-02'),
-- CR-V
(1, 2, 'COMP',     NULL, 500, NULL, NULL, '2022-01-15', NULL),
(1, 2, 'COLL',     NULL, 500, NULL, NULL, '2022-01-15', '2025-09-01'),
(1, 2, 'COLL',     NULL, 1000, NULL, NULL, '2025-09-01', NULL),
(1, 2, 'ROADSIDE', NULL, NULL, NULL, '{"remolque_millas":15}', '2022-01-15', '2025-09-01'),
(1, 2, 'RENTAL',   '$30/día, $900 máx', NULL, 'R30', '{"limite_diario":30,"maximo_evento":900,"dias_max":30,"clase":"Economy / Compact"}', '2022-08-03', '2023-03-10'),
(1, 2, 'RENTAL',   '$50/día, $1,500 máx', NULL, 'R50', '{"limite_diario":50,"maximo_evento":1500,"dias_max":30,"clase":"Full-size sedan / Small SUV"}', '2023-03-10', '2025-02-14'),
(1, 2, 'RENTAL',   '$40/día, $1,200 máx', NULL, 'R40', '{"limite_diario":40,"maximo_evento":1200,"dias_max":30,"clase":"Intermediate / Standard"}', '2025-02-14', NULL),
-- Tacoma (alta 2024-05-02)
(1, 3, 'COMP',     NULL, 500, NULL, NULL, '2024-05-02', NULL),
(1, 3, 'COLL',     NULL, 500, NULL, NULL, '2024-05-02', NULL),
(1, 3, 'RENTAL',   '$40/día, $1,200 máx', NULL, 'R40', '{"limite_diario":40,"maximo_evento":1200,"dias_max":30,"clase":"Intermediate / Standard"}', '2024-05-02', NULL),
(1, 3, 'CRA',      '20% sobre ACV', NULL, NULL, '{"porcentaje_extra":20}', '2024-05-02', NULL),

-- Póliza 2 (VA)
(2, NULL, 'BI',    '$250,000/$500,000', NULL, NULL, NULL, '2023-06-01', NULL),
(2, NULL, 'PD',    '$100,000',          NULL, NULL, NULL, '2023-06-01', NULL),
(2, NULL, 'UMUIM', '$250,000/$500,000', NULL, NULL, NULL, '2023-06-01', NULL),
(2, NULL, 'MEDPAY','$5,000',            NULL, NULL, NULL, '2023-06-01', NULL),
(2, NULL, 'AF',    NULL,                NULL, NULL, NULL, '2024-10-12', NULL),
(2, 4, 'COMP',     NULL, 250, NULL, NULL, '2023-06-01', NULL),
(2, 4, 'COLL',     NULL, 500, NULL, NULL, '2023-06-01', NULL),
(2, 4, 'RENTAL',   '$60/día, $1,800 máx', NULL, 'R60', '{"limite_diario":60,"maximo_evento":1800,"dias_max":30,"clase":"Mid-size SUV / Minivan / Pickup"}', '2023-06-01', '2026-02-20');

-- ---------------------------------------------------------------------
-- 4. TRANSACCIONES (historial de cambios)
-- ---------------------------------------------------------------------

CREATE TABLE transacciones (
    id              INTEGER PRIMARY KEY,
    poliza_id       INTEGER NOT NULL REFERENCES polizas(id),
    fecha           DATE NOT NULL,
    tipo            TEXT NOT NULL CHECK (tipo IN ('ALTA_POLIZA','AGREGAR','ELIMINAR','MODIFICAR')),
    objeto          TEXT NOT NULL CHECK (objeto IN ('POLIZA','COBERTURA','VEHICULO')),
    codigo_cobertura TEXT REFERENCES catalogo_coberturas(codigo),
    vehiculo_id     INTEGER REFERENCES vehiculos(id),
    valor_anterior  TEXT,
    valor_nuevo     TEXT,
    canal           TEXT NOT NULL CHECK (canal IN ('TELEFONO','APP','WEB')),
    llamada_id      INTEGER,        -- llamada que originó el cambio (si hubo)
    representante   TEXT
);

INSERT INTO transacciones VALUES
(1,  1, '2022-01-15', 'ALTA_POLIZA', 'POLIZA',    NULL,      NULL, NULL,   'Nueva póliza: F-150 y CR-V', 'WEB',      NULL, NULL),
(2,  1, '2022-08-03', 'AGREGAR',     'COBERTURA', 'RENTAL',  2,    NULL,   'R30 ($30/día)',  'TELEFONO', 1, 'J. Whitfield'),
(3,  1, '2023-03-10', 'MODIFICAR',   'COBERTURA', 'RENTAL',  2,    'R30 ($30/día)', 'R50 ($50/día)', 'TELEFONO', 2, 'S. Ramirez'),
(4,  1, '2024-05-02', 'ELIMINAR',    'VEHICULO',  NULL,      1,    '2019 Ford F-150', NULL, 'TELEFONO', 4, 'K. Nguyen'),
(5,  1, '2024-05-02', 'AGREGAR',     'VEHICULO',  NULL,      3,    NULL,   '2024 Toyota Tacoma', 'TELEFONO', 4, 'K. Nguyen'),
(6,  1, '2024-05-02', 'AGREGAR',     'COBERTURA', 'RENTAL',  3,    NULL,   'R40 ($40/día)',  'TELEFONO', 4, 'K. Nguyen'),
(7,  1, '2024-05-02', 'AGREGAR',     'COBERTURA', 'CRA',     3,    NULL,   '20% sobre ACV',  'APP',      NULL, NULL),
(8,  1, '2025-02-14', 'MODIFICAR',   'COBERTURA', 'RENTAL',  2,    'R50 ($50/día)', 'R40 ($40/día)', 'TELEFONO', 5, 'L. Carter'),
(9,  1, '2025-09-01', 'MODIFICAR',   'COBERTURA', 'COLL',    2,    'Deducible $500', 'Deducible $1,000', 'TELEFONO', 6, 'M. Okafor'),
(10, 1, '2025-09-01', 'ELIMINAR',    'COBERTURA', 'ROADSIDE',2,    'Roadside Assistance', NULL, 'TELEFONO', 6, 'M. Okafor'),
(11, 2, '2023-06-01', 'ALTA_POLIZA', 'POLIZA',    NULL,      NULL, NULL,   'Nueva póliza: Pacifica con RENTAL R60', 'WEB', NULL, NULL),
(12, 2, '2024-10-12', 'AGREGAR',     'COBERTURA', 'AF',      NULL, NULL,   'Accident Forgiveness', 'WEB', NULL, NULL),
(13, 2, '2026-02-20', 'ELIMINAR',    'COBERTURA', 'RENTAL',  4,    'R60 ($60/día)', NULL, 'TELEFONO', 7, 'D. Patel');

-- ---------------------------------------------------------------------
-- 5. LLAMADAS (audio sintético + transcript)
-- ---------------------------------------------------------------------

CREATE TABLE llamadas (
    id              INTEGER PRIMARY KEY,
    poliza_id       INTEGER NOT NULL REFERENCES polizas(id),
    fecha_hora      DATETIME NOT NULL,
    duracion_seg    INTEGER NOT NULL,
    representante   TEXT NOT NULL,
    archivo_audio   TEXT NOT NULL,
    motivo          TEXT,
    resumen         TEXT,          -- lo llena la IA
    highlights      TEXT           -- JSON, lo llena la IA
);

INSERT INTO llamadas VALUES
(1, 1, '2022-08-03 10:14:00', 312, 'J. Whitfield', 'audio/call_001.mp3', 'Agregar rental reimbursement', NULL, NULL),
(2, 1, '2023-03-10 16:42:00', 405, 'S. Ramirez',   'audio/call_002.mp3', 'Subir nivel de rental', NULL, NULL),
(3, 1, '2023-11-20 09:05:00', 268, 'T. Morales',   'audio/call_003.mp3', 'Consulta sobre rental en F-150', NULL, NULL),
(4, 1, '2024-05-02 13:30:00', 610, 'K. Nguyen',    'audio/call_004.mp3', 'Reemplazo de vehículo', NULL, NULL),
(5, 1, '2025-02-14 11:20:00', 455, 'L. Carter',    'audio/call_005.mp3', 'Reducir costo de póliza', NULL, NULL),
(6, 1, '2025-09-01 15:10:00', 520, 'M. Okafor',    'audio/call_006.mp3', 'Cambios de deducible y coberturas', NULL, NULL),
(7, 2, '2026-02-20 08:55:00', 290, 'D. Patel',     'audio/call_007.mp3', 'Eliminar rental reimbursement', NULL, NULL);

CREATE TABLE segmentos (
    id          INTEGER PRIMARY KEY,
    llamada_id  INTEGER NOT NULL REFERENCES llamadas(id),
    orden       INTEGER NOT NULL,
    inicio_seg  INTEGER NOT NULL,
    hablante    TEXT NOT NULL CHECK (hablante IN ('MIEMBRO','REPRESENTANTE')),
    texto       TEXT NOT NULL
);

INSERT INTO segmentos (llamada_id, orden, inicio_seg, hablante, texto) VALUES
-- Llamada 1: agregar rental R30 al CR-V
(1,1,0,  'REPRESENTANTE','Thank you for calling USAA, this is Jordan. How can I help you today?'),
(1,2,8,  'MIEMBRO',      'Hi, I want to add rental car coverage to my Honda CR-V. My wife uses it every day.'),
(1,3,21, 'REPRESENTANTE','Sure. We have rental reimbursement at 30, 40, 50 or 60 dollars a day, up to 30 days per claim.'),
(1,4,55, 'MIEMBRO',      'Let''s do the 30 dollar one for now, just the basic.'),
(1,5,70, 'REPRESENTANTE','Done. Rental reimbursement at 30 dollars a day, 900 max, is added to the CR-V effective today.'),
-- Llamada 2: subir a R50
(2,1,0,  'REPRESENTANTE','USAA, this is Sofia. How can I help?'),
(2,2,6,  'MIEMBRO',      'Last time I had a claim the rental they gave me was tiny. What kind of car does my coverage get me?'),
(2,3,25, 'REPRESENTANTE','With 30 dollars a day you''re in the economy or compact class, something like a Nissan Versa.'),
(2,4,48, 'MIEMBRO',      'We have two kids. What would I need for something like a Camry or a small SUV?'),
(2,5,60, 'REPRESENTANTE','That would be the 50 dollar a day level, full-size sedan or small SUV, 1,500 max per claim.'),
(2,6,82, 'MIEMBRO',      'Okay, please change it to the 50.'),
(2,7,90, 'REPRESENTANTE','Updated. Your CR-V now has rental reimbursement at 50 dollars a day, effective today.'),
-- Llamada 3: solo consulta, sin cambio (caso trampa)
(3,1,0,  'REPRESENTANTE','Thanks for calling USAA, this is Tomas.'),
(3,2,5,  'MIEMBRO',      'Quick question, does my F-150 have rental coverage too?'),
(3,3,18, 'REPRESENTANTE','No, rental reimbursement is only on the CR-V right now. I can add it to the F-150 if you''d like.'),
(3,4,35, 'MIEMBRO',      'How much would that be?'),
(3,5,40, 'REPRESENTANTE','About six dollars a month for the 30 dollar level.'),
(3,6,52, 'MIEMBRO',      'Let me think about it and talk to my wife. Don''t change anything for now.'),
-- Llamada 4: reemplazo F-150 por Tacoma
(4,1,0,  'REPRESENTANTE','USAA, this is Kim speaking.'),
(4,2,6,  'MIEMBRO',      'I traded in my F-150 and bought a 2024 Tacoma. I need to swap it on my policy.'),
(4,3,30, 'REPRESENTANTE','I''ll remove the F-150 and add the Tacoma. Do you want the same comprehensive and collision, 500 deductible?'),
(4,4,48, 'MIEMBRO',      'Yes. And this time I do want rental on the truck. What gets me a pickup?'),
(4,5,62, 'REPRESENTANTE','A pickup rental is the 60 dollar level. The 40 dollar level covers a standard sedan like a Corolla.'),
(4,6,85, 'MIEMBRO',      'Go with 40, I can drive a sedan for a couple weeks.'),
(4,7,95, 'REPRESENTANTE','Done. F-150 removed, Tacoma added with comprehensive, collision and rental at 40 dollars a day.'),
-- Llamada 5: quiere eliminar rental y cambia de opinión (caso trampa)
(5,1,0,  'REPRESENTANTE','USAA, this is Lauren.'),
(5,2,5,  'MIEMBRO',      'I need to lower my premium. Can you remove the rental coverage from the CR-V?'),
(5,3,20, 'REPRESENTANTE','I can. Just so you know, without it you''d pay for any rental yourself after a covered claim.'),
(5,4,42, 'MIEMBRO',      'Hmm. What if I just go down a level instead of removing it?'),
(5,5,50, 'REPRESENTANTE','Going from 50 to 40 dollars a day saves a bit and you keep a standard sedan class.'),
(5,6,70, 'MIEMBRO',      'Okay, don''t remove it. Lower it to 40.'),
(5,7,78, 'REPRESENTANTE','Updated, rental on the CR-V is now 40 dollars a day, effective today.'),
-- Llamada 6: deducible + roadside + rideshare prometido pero NO aplicado
(6,1,0,  'REPRESENTANTE','USAA, this is Michael.'),
(6,2,5,  'MIEMBRO',      'I want to raise the collision deductible on the CR-V to 1,000 and drop roadside on it.'),
(6,3,22, 'REPRESENTANTE','Collision deductible is now 1,000 and roadside is removed from the CR-V.'),
(6,4,40, 'MIEMBRO',      'Also, my wife started driving for Uber on weekends with the CR-V. Does she need anything?'),
(6,5,55, 'REPRESENTANTE','Yes, you''ll want rideshare gap protection. I''ll add that to the CR-V for you.'),
(6,6,68, 'MIEMBRO',      'Great, thanks.'),
-- Llamada 7: póliza 2 elimina rental
(7,1,0,  'REPRESENTANTE','USAA, this is Dev.'),
(7,2,5,  'MIEMBRO',      'I have a second car now I can use if the Pacifica is in the shop. Please remove the rental coverage.'),
(7,3,20, 'REPRESENTANTE','Okay, rental reimbursement at 60 dollars a day is removed from the Pacifica effective today.');

-- Eventos que la IA extrae de cada llamada
CREATE TABLE eventos_llamada (
    id              INTEGER PRIMARY KEY,
    llamada_id      INTEGER NOT NULL REFERENCES llamadas(id),
    segmento_id     INTEGER REFERENCES segmentos(id),
    tipo_evento     TEXT NOT NULL CHECK (tipo_evento IN
                    ('SOLICITUD_CAMBIO','CONSULTA','CAMBIO_DE_OPINION','CONFIRMACION','PROMESA_REPRESENTANTE')),
    descripcion     TEXT NOT NULL,
    codigo_cobertura TEXT REFERENCES catalogo_coberturas(codigo),
    transaccion_id  INTEGER REFERENCES transacciones(id),  -- NULL = sin transacción
    requiere_revision INTEGER NOT NULL DEFAULT 0            -- 1 = alerta CRU
);

-- Ejemplo de lo que debería producir la extracción (respuesta correcta)
INSERT INTO eventos_llamada (llamada_id, segmento_id, tipo_evento, descripcion, codigo_cobertura, transaccion_id, requiere_revision)
SELECT 1, id, 'SOLICITUD_CAMBIO', 'Miembro pide agregar rental $30/día al CR-V', 'RENTAL', 2, 0 FROM segmentos WHERE llamada_id=1 AND orden=4 UNION ALL
SELECT 2, id, 'CONSULTA',         'Miembro pregunta qué clase de auto cubre su rental', 'RENTAL', NULL, 0 FROM segmentos WHERE llamada_id=2 AND orden=2 UNION ALL
SELECT 2, id, 'SOLICITUD_CAMBIO', 'Miembro pide subir rental a $50/día (full-size/small SUV)', 'RENTAL', 3, 0 FROM segmentos WHERE llamada_id=2 AND orden=6 UNION ALL
SELECT 3, id, 'CONSULTA',         'Pregunta si la F-150 tiene rental; decide no cambiar nada', 'RENTAL', NULL, 0 FROM segmentos WHERE llamada_id=3 AND orden=6 UNION ALL
SELECT 4, id, 'SOLICITUD_CAMBIO', 'Reemplazar F-150 por Tacoma 2024 y agregar rental $40/día', 'RENTAL', 6, 0 FROM segmentos WHERE llamada_id=4 AND orden=6 UNION ALL
SELECT 5, id, 'SOLICITUD_CAMBIO', 'Miembro pide eliminar rental del CR-V', 'RENTAL', NULL, 0 FROM segmentos WHERE llamada_id=5 AND orden=2 UNION ALL
SELECT 5, id, 'CAMBIO_DE_OPINION','No eliminar; bajar rental a $40/día', 'RENTAL', 8, 0 FROM segmentos WHERE llamada_id=5 AND orden=6 UNION ALL
SELECT 6, id, 'SOLICITUD_CAMBIO', 'Subir deducible de collision a $1,000 y quitar roadside', 'COLL', 9, 0 FROM segmentos WHERE llamada_id=6 AND orden=2 UNION ALL
SELECT 6, id, 'PROMESA_REPRESENTANTE','Representante dice que agregará Rideshare Gap al CR-V; NO existe transacción', 'RSG', NULL, 1 FROM segmentos WHERE llamada_id=6 AND orden=5 UNION ALL
SELECT 7, id, 'SOLICITUD_CAMBIO', 'Miembro pide eliminar rental de la Pacifica', 'RENTAL', 13, 0 FROM segmentos WHERE llamada_id=7 AND orden=2;

-- ---------------------------------------------------------------------
-- 6. VISTAS PARA EL CHATBOT
-- ---------------------------------------------------------------------

-- Coberturas vigentes hoy con detalle de renta
CREATE VIEW v_coberturas_vigentes AS
SELECT p.numero_poliza, m.nombre AS miembro,
       COALESCE(v.anio||' '||v.marca||' '||v.modelo, '(nivel póliza)') AS vehiculo,
       c.codigo, cc.nombre AS cobertura, c.limite, c.deducible,
       n.clase_vehiculo AS clase_renta, n.ejemplos AS autos_renta_ejemplo,
       c.vigente_desde
FROM coberturas c
JOIN polizas p ON p.id = c.poliza_id
JOIN miembros m ON m.id = p.miembro_id
JOIN catalogo_coberturas cc ON cc.codigo = c.codigo
LEFT JOIN vehiculos v ON v.id = c.vehiculo_id
LEFT JOIN niveles_renta n ON n.codigo = c.nivel_renta
WHERE c.vigente_hasta IS NULL;

-- Historial de transacciones con su periodo y la llamada que lo originó
CREATE VIEW v_historial AS
SELECT t.id AS transaccion_id, p.numero_poliza, per.numero AS periodo,
       t.fecha, t.tipo, t.objeto, t.codigo_cobertura,
       COALESCE(v.anio||' '||v.marca||' '||v.modelo, '') AS vehiculo,
       t.valor_anterior, t.valor_nuevo, t.canal, t.llamada_id
FROM transacciones t
JOIN polizas p ON p.id = t.poliza_id
JOIN periodos per ON per.poliza_id = t.poliza_id
     AND t.fecha >= per.fecha_inicio AND t.fecha < per.fecha_fin
LEFT JOIN vehiculos v ON v.id = t.vehiculo_id;

-- Evidencia: lo dicho en la llamada vs. lo aplicado en la póliza
CREATE VIEW v_evidencia_cru AS
SELECT l.id AS llamada_id, l.fecha_hora, p.numero_poliza,
       e.tipo_evento, e.descripcion, e.codigo_cobertura,
       printf('%d:%02d', s.inicio_seg/60, s.inicio_seg%60) AS minuto,
       s.hablante, s.texto AS cita,
       e.transaccion_id,
       CASE WHEN e.requiere_revision = 1 THEN 'ALERTA: prometido en llamada, no aplicado'
            WHEN e.transaccion_id IS NOT NULL THEN 'Aplicado'
            WHEN e.tipo_evento = 'SOLICITUD_CAMBIO' THEN 'Solicitado y retractado en la misma llamada'
            ELSE 'Sin cambio (consulta)' END AS resultado
FROM eventos_llamada e
JOIN llamadas l ON l.id = e.llamada_id
JOIN polizas p ON p.id = l.poliza_id
LEFT JOIN segmentos s ON s.id = e.segmento_id;
