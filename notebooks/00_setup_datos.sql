-- Databricks notebook source
-- MAGIC %md
-- MAGIC # Setup de datos: Inchcape Andina, posventa y repuestos
-- MAGIC
-- MAGIC Este notebook crea el catálogo `inchcape_workshop` con toda la data del taller.
-- MAGIC Es idempotente: podés correrlo las veces que quieras y siempre deja el mismo resultado.
-- MAGIC
-- MAGIC **Cómo se corre:** `Run all`. Tarda entre 2 y 4 minutos en el warehouse serverless.
-- MAGIC
-- MAGIC **Qué NO necesita:** ni `pip install`, ni internet, ni subir archivos. Solo SQL.
-- MAGIC Todo se genera con funciones nativas de Spark, y los valores son deterministas:
-- MAGIC a todos les van a salir exactamente los mismos números.
-- MAGIC
-- MAGIC La historia completa está en [HISTORIA.md](../HISTORIA.md).

-- COMMAND ----------

CREATE CATALOG IF NOT EXISTS inchcape_workshop;

-- COMMAND ----------

CREATE SCHEMA IF NOT EXISTS inchcape_workshop.ops
  COMMENT 'Operación de posventa y repuestos de Inchcape Andina: red, materiales, ventas, inventario y órdenes de taller.';

-- COMMAND ----------

CREATE SCHEMA IF NOT EXISTS inchcape_workshop.pmo
  COMMENT 'Portafolio de proyectos de la PMO: presupuesto, hitos y avance.';

-- COMMAND ----------

CREATE SCHEMA IF NOT EXISTS inchcape_workshop.raw
  COMMENT 'Extractos crudos estilo SAP, tal como llegan del origen y con la suciedad del origen.';

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 1. `ops.dim_dealer`: la red de concesionarios y talleres

-- COMMAND ----------

CREATE OR REPLACE TABLE inchcape_workshop.ops.dim_dealer (
  dealer_id       STRING        COMMENT 'Código único del punto de la red. Formato D0001.',
  dealer_nombre   STRING        COMMENT 'Nombre comercial del concesionario o taller.',
  pais            STRING        COMMENT 'País de operación: Colombia, Perú o Chile.',
  ciudad          STRING        COMMENT 'Ciudad donde opera el punto.',
  region          STRING        COMMENT 'Región comercial dentro del país: Norte, Centro o Sur.',
  marca           STRING        COMMENT 'Marca de vehículos que representa el punto.',
  tipo_punto      STRING        COMMENT 'Tipo de punto: Concesionario, Taller Autorizado o Punto Repuestos.',
  bahias          INT           COMMENT 'Cantidad de bahías de taller. Es la capacidad de servicio del punto: si una bahía está parada esperando un repuesto, ese ingreso se pierde.',
  tarifa_hora_usd DECIMAL(8,2)  COMMENT 'Tarifa de mano de obra por hora de bahía, en USD.',
  fecha_apertura  DATE          COMMENT 'Fecha de apertura del punto.',
  activo          BOOLEAN       COMMENT 'Indica si el punto está operando actualmente.'
)
COMMENT 'Red de concesionarios y talleres de Inchcape Andina. Una fila por punto de la red. 120 puntos en Colombia, Perú y Chile.'
TBLPROPERTIES ('capa' = 'gold', 'dominio' = 'posventa');

-- COMMAND ----------

INSERT INTO inchcape_workshop.ops.dim_dealer
WITH base AS (
  SELECT
    id AS n,
    pmod(hash(id, 'ciudad'), 19) + 1  AS idx_ciudad,
    pmod(hash(id, 'marca'), 8) + 1    AS idx_marca,
    pmod(hash(id, 'tipo'), 10) + 1    AS idx_tipo,
    pmod(hash(id, 'region'), 3) + 1   AS idx_region
  FROM range(1, 121)
)
SELECT
  concat('D', lpad(CAST(n AS STRING), 4, '0')),
  concat(
    element_at(array('Inchcape', 'Automotores', 'Autonorte', 'Distribuidora', 'Grupo'), pmod(hash(n, 'nom1'), 5) + 1),
    ' ',
    element_at(array('Andina', 'Central', 'Pacífico', 'del Valle', 'Real', 'Continental', 'Metropolitana'), pmod(hash(n, 'nom2'), 7) + 1),
    ' ', lpad(CAST(n AS STRING), 3, '0')
  ),
  CASE WHEN idx_ciudad <= 7 THEN 'Colombia' WHEN idx_ciudad <= 13 THEN 'Perú' ELSE 'Chile' END,
  element_at(array(
    'Bogotá', 'Medellín', 'Cali', 'Barranquilla', 'Bucaramanga', 'Cartagena', 'Pereira',
    'Lima', 'Arequipa', 'Trujillo', 'Piura', 'Chiclayo', 'Cusco',
    'Santiago', 'Valparaíso', 'Concepción', 'Antofagasta', 'Temuco', 'La Serena'
  ), idx_ciudad),
  element_at(array('Norte', 'Centro', 'Sur'), idx_region),
  element_at(array('Toyota', 'Lexus', 'Hino', 'Suzuki', 'Subaru', 'BMW', 'MINI', 'Jaguar Land Rover'), idx_marca),
  CASE WHEN idx_tipo <= 5 THEN 'Concesionario' WHEN idx_tipo <= 8 THEN 'Taller Autorizado' ELSE 'Punto Repuestos' END,
  CASE
    WHEN idx_tipo <= 5 THEN 6 + pmod(hash(n, 'bah'), 9)
    WHEN idx_tipo <= 8 THEN 3 + pmod(hash(n, 'bah'), 5)
    ELSE 0
  END,
  CAST(38 + pmod(hash(n, 'tar'), 34) AS DECIMAL(8, 2)),
  date_add(DATE'2005-01-01', pmod(hash(n, 'fap'), 7000)),
  pmod(hash(n, 'act'), 50) > 0
FROM base;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 2. `ops.dim_material`: el maestro de repuestos
-- MAGIC
-- MAGIC Ojo con esta tabla: trae los problemas de calidad reales del maestro.
-- MAGIC Hay descripciones duplicadas con códigos distintos, proveedores en blanco y precios en cero.
-- MAGIC Uno de esos duplicados es la causa raíz de la historia.

-- COMMAND ----------

CREATE OR REPLACE TABLE inchcape_workshop.ops.dim_material (
  material_id       STRING        COMMENT 'Código único del repuesto. Formato MAT-00001.',
  material_desc     STRING        COMMENT 'Descripción del repuesto. Cuidado: hay descripciones repetidas con material_id distinto, o sea el mismo repuesto cargado dos veces en el maestro.',
  familia           STRING        COMMENT 'Familia del repuesto: Filtros, Frenos, Suspensión, Motor, Eléctrico, Carrocería, Lubricantes, Neumáticos, Transmisión o Refrigeración.',
  marca_vehiculo    STRING        COMMENT 'Marca de vehículo a la que aplica el repuesto.',
  proveedor         STRING        COMMENT 'Proveedor del repuesto. Puede venir en NULL cuando el maestro está incompleto.',
  precio_lista_usd  DECIMAL(10,2) COMMENT 'Precio de lista en USD. Puede venir en cero cuando el maestro está incompleto.',
  costo_usd         DECIMAL(10,2) COMMENT 'Costo unitario en USD.',
  lead_time_dias    INT           COMMENT 'Días entre el pedido al proveedor y la recepción en el centro de distribución.',
  criticidad        STRING        COMMENT 'Clasificación ABC: A es crítico para la operación del taller, C es accesorio.',
  es_alta_rotacion  BOOLEAN       COMMENT 'Indica si el repuesto es de alta rotación. Los de alta rotación concentran la mayor parte de la venta.'
)
COMMENT 'Maestro de repuestos de Inchcape Andina. 800 materiales. Contiene defectos de calidad intencionales: descripciones duplicadas con códigos distintos, proveedores nulos y precios en cero.'
TBLPROPERTIES ('capa' = 'gold', 'dominio' = 'posventa');

-- COMMAND ----------

INSERT INTO inchcape_workshop.ops.dim_material
WITH base AS (
  SELECT
    id AS n,
    -- Los primeros 12 materiales reciben la descripción de otro material:
    -- así nacen los duplicados del maestro, con código distinto.
    CASE WHEN id <= 12 THEN id + 400 ELSE id END AS semilla_desc,
    pmod(hash(id, 'prov'), 8) + 1 AS idx_prov,
    pmod(hash(id, 'fam'), 10) + 1 AS idx_fam
  FROM range(1, 801)
),
enr AS (
  SELECT
    n,
    semilla_desc,
    idx_prov,
    element_at(array('Filtros', 'Frenos', 'Suspensión', 'Motor', 'Eléctrico', 'Carrocería', 'Lubricantes', 'Neumáticos', 'Transmisión', 'Refrigeración'), idx_fam) AS familia,
    element_at(array('Denso Andina', 'Nippon Parts', 'Bosch Latam', 'Aisin Supply', 'Exedy Andes', 'TRW Región', 'NGK Distribución', 'Valeo Andina'), idx_prov) AS proveedor,
    n <= 160 AS alta_rotacion
  FROM base
)
SELECT
  concat('MAT-', lpad(CAST(n AS STRING), 5, '0')),
  concat(
    element_at(array('Filtro', 'Pastilla', 'Amortiguador', 'Bujía', 'Correa', 'Bomba', 'Sensor', 'Radiador', 'Embrague', 'Rodamiento'), pmod(hash(semilla_desc, 'd1'), 10) + 1),
    ' ',
    element_at(array('aceite', 'aire', 'freno delantero', 'freno trasero', 'combustible', 'distribución', 'agua', 'cabina', 'transmisión', 'dirección'), pmod(hash(semilla_desc, 'd2'), 10) + 1),
    ' ',
    element_at(array('OEM', 'Genuino', 'Premium', 'Estándar', 'Reforzado'), pmod(hash(semilla_desc, 'd3'), 5) + 1),
    ' ', lpad(CAST(pmod(hash(semilla_desc, 'd4'), 9000) + 1000 AS STRING), 4, '0')
  ),
  familia,
  element_at(array('Toyota', 'Lexus', 'Hino', 'Suzuki', 'Subaru', 'BMW', 'MINI', 'Jaguar Land Rover'), pmod(hash(n, 'mv'), 8) + 1),
  -- 3% del maestro sin proveedor
  CASE WHEN pmod(hash(n, 'nulprov'), 100) < 3 THEN NULL ELSE proveedor END,
  -- 2% del maestro con precio en cero
  CASE
    WHEN pmod(hash(n, 'p0'), 100) < 2 THEN CAST(0 AS DECIMAL(10, 2))
    WHEN alta_rotacion THEN CAST(18 + pmod(hash(n, 'pr'), 220) AS DECIMAL(10, 2))
    ELSE CAST(30 + pmod(hash(n, 'pr'), 900) AS DECIMAL(10, 2))
  END,
  CASE
    WHEN alta_rotacion THEN CAST(round((18 + pmod(hash(n, 'pr'), 220)) * 0.62, 2) AS DECIMAL(10, 2))
    ELSE CAST(round((30 + pmod(hash(n, 'pr'), 900)) * 0.58, 2) AS DECIMAL(10, 2))
  END,
  -- Nippon Parts es el proveedor con lead time más largo, y ahí empieza el problema
  CASE WHEN idx_prov = 2 THEN 45 + pmod(hash(n, 'lt'), 30) ELSE 7 + pmod(hash(n, 'lt'), 28) END,
  CASE WHEN alta_rotacion THEN 'A' WHEN n <= 400 THEN 'B' ELSE 'C' END,
  alta_rotacion
FROM enr;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 3. `ops.fact_supply_incident`: los eventos de abastecimiento
-- MAGIC
-- MAGIC Acá está el evento raíz de la historia. Cuando encuentres una anomalía en las
-- MAGIC otras tablas, esta tabla te explica por qué pasó.

-- COMMAND ----------

CREATE OR REPLACE TABLE inchcape_workshop.ops.fact_supply_incident (
  incidente_id        STRING  COMMENT 'Código del incidente de abastecimiento. Formato INC-0001.',
  fecha_inicio        DATE    COMMENT 'Fecha en que se detectó el incidente.',
  fecha_fin           DATE    COMMENT 'Fecha en que se resolvió el incidente.',
  proveedor           STRING  COMMENT 'Proveedor involucrado.',
  tipo                STRING  COMMENT 'Tipo de incidente: Retraso Proveedor, Falla Calidad, Retención Aduana o Duplicado Maestro.',
  severidad           STRING  COMMENT 'Severidad: Crítica, Alta, Media o Baja.',
  materiales_afectados INT    COMMENT 'Cantidad de materiales afectados por el incidente.',
  descripcion         STRING  COMMENT 'Descripción de lo que pasó.'
)
COMMENT 'Incidentes de abastecimiento de repuestos. Explica las anomalías que se ven en inventario, ventas y órdenes de taller. El incidente INC-0001 es la causa raíz del período crítico de marzo y abril de 2026.'
TBLPROPERTIES ('capa' = 'gold', 'dominio' = 'posventa');

-- COMMAND ----------

INSERT INTO inchcape_workshop.ops.fact_supply_incident
SELECT 'INC-0001', DATE'2026-03-02', DATE'2026-04-17', 'Nippon Parts', 'Retraso Proveedor', 'Crítica', 100,
       'Nippon Parts suspendió embarques durante seis semanas por un paro en su planta. Afectó los 100 materiales que ese proveedor abastece, incluidos repuestos de alta rotación de las familias Filtros y Frenos.'
UNION ALL
SELECT 'INC-0002', DATE'2026-03-02', DATE'2026-04-17', 'Nippon Parts', 'Duplicado Maestro', 'Crítica', 12,
       'Doce repuestos estaban cargados dos veces en el maestro de materiales con códigos distintos. El cálculo de punto de reorden usó solo una de las dos entradas, así que la señal de demanda quedó partida a la mitad y el reabastecimiento se disparó tarde.'
UNION ALL
SELECT
  concat('INC-', lpad(CAST(id + 2 AS STRING), 4, '0')),
  date_add(DATE'2025-08-01', pmod(hash(id, 'ini'), 330)),
  date_add(date_add(DATE'2025-08-01', pmod(hash(id, 'ini'), 330)), 3 + pmod(hash(id, 'dur'), 18)),
  element_at(array('Denso Andina', 'Bosch Latam', 'Aisin Supply', 'Exedy Andes', 'TRW Región', 'NGK Distribución', 'Valeo Andina'), pmod(hash(id, 'prov'), 7) + 1),
  element_at(array('Retraso Proveedor', 'Falla Calidad', 'Retención Aduana'), pmod(hash(id, 'tipo'), 3) + 1),
  element_at(array('Alta', 'Media', 'Media', 'Baja'), pmod(hash(id, 'sev'), 4) + 1),
  2 + pmod(hash(id, 'mat'), 14),
  'Incidente puntual de abastecimiento, resuelto dentro del mes.'
FROM range(1, 39);

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 4. `ops.fact_parts_sales`: la venta de repuestos
-- MAGIC
-- MAGIC Doce meses de venta, de agosto 2025 a julio 2026. Cerca de 190 mil líneas.
-- MAGIC El 20% de los materiales concentra la mayor parte del ingreso, como en la vida real.

-- COMMAND ----------

CREATE OR REPLACE TABLE inchcape_workshop.ops.fact_parts_sales (
  venta_id            STRING        COMMENT 'Código de la línea de venta. Formato SO-0000001.',
  fecha               DATE          COMMENT 'Fecha de la venta.',
  dealer_id           STRING        COMMENT 'Punto de la red que hizo la venta. Se une con ops.dim_dealer.',
  material_id         STRING        COMMENT 'Repuesto vendido. Se une con ops.dim_material.',
  canal               STRING        COMMENT 'Canal de venta: Taller, Mostrador, Mayorista o E-commerce.',
  cantidad            INT           COMMENT 'Unidades vendidas en la línea.',
  precio_unitario_usd DECIMAL(10,2) COMMENT 'Precio unitario aplicado, en USD.',
  descuento_pct       DECIMAL(5,2)  COMMENT 'Descuento aplicado, en porcentaje.',
  monto_usd           DECIMAL(12,2) COMMENT 'Ingreso de la línea en USD, ya con el descuento aplicado. Es la métrica de venta.'
)
COMMENT 'Venta de repuestos de Inchcape Andina, agosto 2025 a julio 2026. Una fila por línea de venta. La venta de los materiales de Nippon Parts cae fuerte entre el 2 de marzo y el 17 de abril de 2026 por el incidente INC-0001.'
TBLPROPERTIES ('capa' = 'gold', 'dominio' = 'posventa');

-- COMMAND ----------

INSERT INTO inchcape_workshop.ops.fact_parts_sales
WITH base AS (
  SELECT
    id AS n,
    date_add(DATE'2025-08-01', pmod(hash(id, 'fecha'), 365)) AS fecha,
    -- 80% de las líneas caen en el 20% de materiales de alta rotación
    CASE
      WHEN pmod(hash(id, 'skew'), 100) < 80 THEN pmod(hash(id, 'matA'), 160) + 1
      ELSE 161 + pmod(hash(id, 'matB'), 640)
    END AS idx_material,
    pmod(hash(id, 'dealer'), 120) + 1 AS idx_dealer,
    pmod(hash(id, 'canal'), 10) + 1 AS idx_canal
  FROM range(1, 200001)
),
-- El proveedor se lee del maestro, no se recalcula: así el incidente cae
-- exactamente sobre los materiales que dim_material dice que son de Nippon Parts.
unido AS (
  SELECT
    b.n, b.fecha, b.idx_dealer, b.idx_canal,
    m.material_id,
    coalesce(m.proveedor, 'Sin Proveedor') AS proveedor,
    greatest(m.precio_lista_usd, CAST(12 AS DECIMAL(10, 2))) AS precio_unitario_usd,
    CASE WHEN b.idx_canal IN (8, 9) THEN 6 + pmod(hash(b.n, 'cant'), 40)
         ELSE 1 + pmod(hash(b.n, 'cant'), 6) END AS cantidad,
    CAST(element_at(array(0, 0, 0, 5, 5, 8, 10, 12, 15, 20), pmod(hash(b.n, 'desc'), 10) + 1) AS DECIMAL(5, 2)) AS descuento_pct
  FROM base b
  JOIN inchcape_workshop.ops.dim_material m
    ON m.material_id = concat('MAT-', lpad(CAST(b.idx_material AS STRING), 5, '0'))
),
filtrado AS (
  SELECT u.*
  FROM unido u
  WHERE
    -- El domingo casi no hay venta de repuestos
    NOT (dayofweek(u.fecha) = 1 AND pmod(hash(u.n, 'domingo'), 10) < 8)
    -- Durante el incidente INC-0001 se cae el 85% de la venta de materiales de Nippon Parts
    AND NOT (
      u.proveedor = 'Nippon Parts'
      AND u.fecha BETWEEN DATE'2026-03-02' AND DATE'2026-04-17'
      AND pmod(hash(u.n, 'quiebre'), 100) < 85
    )
)
SELECT
  concat('SO-', lpad(CAST(n AS STRING), 7, '0')),
  fecha,
  concat('D', lpad(CAST(idx_dealer AS STRING), 4, '0')),
  material_id,
  CASE WHEN idx_canal <= 5 THEN 'Taller' WHEN idx_canal <= 7 THEN 'Mostrador' WHEN idx_canal <= 9 THEN 'Mayorista' ELSE 'E-commerce' END,
  cantidad,
  precio_unitario_usd,
  descuento_pct,
  CAST(round(cantidad * precio_unitario_usd * (1 - descuento_pct / 100.0), 2) AS DECIMAL(12, 2))
FROM filtrado;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 5. `ops.fact_stock`: foto semanal del inventario
-- MAGIC
-- MAGIC Una foto por semana, por punto de la red y por repuesto de alta rotación.
-- MAGIC Acá se ven los quiebres de stock.

-- COMMAND ----------

CREATE OR REPLACE TABLE inchcape_workshop.ops.fact_stock (
  fecha_snapshot  DATE    COMMENT 'Domingo de la semana a la que corresponde la foto de inventario.',
  dealer_id       STRING  COMMENT 'Punto de la red. Se une con ops.dim_dealer.',
  material_id     STRING  COMMENT 'Repuesto. Se une con ops.dim_material.',
  stock_unidades  INT     COMMENT 'Unidades disponibles en el punto al cierre de la semana.',
  punto_reorden   INT     COMMENT 'Nivel al que se debería disparar el pedido de reabastecimiento.',
  dias_cobertura  INT     COMMENT 'Días de venta que cubre el stock actual al ritmo de demanda de las últimas semanas.',
  en_quiebre      BOOLEAN COMMENT 'Verdadero cuando el stock llegó a cero. Es un quiebre de stock: el taller no puede reparar y la bahía queda parada.'
)
COMMENT 'Foto semanal de inventario de repuestos de alta rotación por punto de la red, agosto 2025 a julio 2026. Los quiebres se concentran entre marzo y abril de 2026 en los materiales de Nippon Parts.'
TBLPROPERTIES ('capa' = 'gold', 'dominio' = 'posventa');

-- COMMAND ----------

INSERT INTO inchcape_workshop.ops.fact_stock
WITH semanas AS (
  SELECT explode(sequence(DATE'2025-08-03', DATE'2026-07-26', INTERVAL 7 DAY)) AS fecha_snapshot
),
puntos AS (
  SELECT dealer_id FROM inchcape_workshop.ops.dim_dealer
),
-- Los 80 materiales de mayor rotación, con su proveedor leído del maestro
materiales AS (
  SELECT material_id, coalesce(proveedor, 'Sin Proveedor') AS proveedor
  FROM inchcape_workshop.ops.dim_material
  WHERE CAST(regexp_replace(material_id, 'MAT-', '') AS INT) <= 80
),
cruce AS (
  SELECT
    s.fecha_snapshot,
    p.dealer_id,
    m.material_id,
    -- ¿Cae este material y esta semana dentro del incidente de Nippon Parts?
    (m.proveedor = 'Nippon Parts' AND s.fecha_snapshot BETWEEN DATE'2026-03-02' AND DATE'2026-04-17') AS en_incidente,
    pmod(hash(s.fecha_snapshot, p.dealer_id, m.material_id, 'stk'), 100) AS r
  FROM semanas s
  CROSS JOIN puntos p
  CROSS JOIN materiales m
)
SELECT
  fecha_snapshot,
  dealer_id,
  material_id,
  CASE
    WHEN en_incidente AND r < 88 THEN 0
    WHEN r < 4 THEN 0
    ELSE 2 + pmod(hash(fecha_snapshot, dealer_id, material_id, 'u'), 90)
  END AS stock_unidades,
  6 + pmod(hash(dealer_id, material_id, 'pr'), 18) AS punto_reorden,
  CASE
    WHEN en_incidente AND r < 88 THEN 0
    WHEN r < 4 THEN 0
    ELSE 1 + pmod(hash(fecha_snapshot, dealer_id, material_id, 'cob'), 45)
  END AS dias_cobertura,
  CASE WHEN (en_incidente AND r < 88) OR r < 4 THEN true ELSE false END AS en_quiebre
FROM cruce;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 6. `ops.fact_workorder`: las órdenes de taller
-- MAGIC
-- MAGIC Acá se cuantifica el daño. Cuando no hay repuesto, la orden se queda esperando,
-- MAGIC la bahía no factura, y esa plata no vuelve.

-- COMMAND ----------

CREATE OR REPLACE TABLE inchcape_workshop.ops.fact_workorder (
  orden_id                STRING        COMMENT 'Código de la orden de servicio. Formato WO-000001.',
  fecha_apertura          DATE          COMMENT 'Fecha en que el vehículo entró al taller.',
  fecha_cierre            DATE          COMMENT 'Fecha en que se entregó el vehículo. NULL si la orden sigue abierta.',
  dealer_id               STRING        COMMENT 'Taller que atendió la orden. Se une con ops.dim_dealer.',
  material_id_principal   STRING        COMMENT 'Repuesto principal que requería la reparación. Se une con ops.dim_material.',
  estado                  STRING        COMMENT 'Estado de la orden: Cerrada, En Proceso o Esperando Repuesto.',
  horas_bahia             DECIMAL(6,2)  COMMENT 'Horas de bahía efectivamente trabajadas en la orden.',
  horas_espera_repuesto   DECIMAL(6,2)  COMMENT 'Horas que la orden estuvo detenida esperando que llegara el repuesto. Es tiempo de bahía que no factura.',
  ingreso_mano_obra_usd   DECIMAL(10,2) COMMENT 'Ingreso facturado por mano de obra, en USD.',
  ingreso_repuestos_usd   DECIMAL(10,2) COMMENT 'Ingreso facturado por repuestos, en USD.',
  costo_espera_usd        DECIMAL(10,2) COMMENT 'Ingreso que se dejó de facturar por las horas de bahía detenidas esperando repuesto, valorizado a la tarifa del punto. Es el impacto en plata del quiebre de stock.',
  sla_cumplido            BOOLEAN       COMMENT 'Verdadero si la orden se cerró dentro del compromiso de 48 horas.'
)
COMMENT 'Órdenes de servicio de los talleres de Inchcape Andina, agosto 2025 a julio 2026. La columna costo_espera_usd cuantifica en dólares el impacto de los quiebres de stock.'
TBLPROPERTIES ('capa' = 'gold', 'dominio' = 'posventa');

-- COMMAND ----------

INSERT INTO inchcape_workshop.ops.fact_workorder
WITH base AS (
  SELECT
    id AS n,
    date_add(DATE'2025-08-01', pmod(hash(id, 'fap'), 365)) AS fecha_apertura,
    concat('D', lpad(CAST(pmod(hash(id, 'dealer'), 120) + 1 AS STRING), 4, '0')) AS dealer_id,
    concat('MAT-', lpad(CAST(pmod(hash(id, 'mat'), 80) + 1 AS STRING), 5, '0')) AS material_id
  FROM range(1, 60001)
),
-- Igual que en ventas: el proveedor se lee del maestro para que el incidente
-- caiga sobre los mismos materiales que en fact_stock.
enr AS (
  SELECT
    b.n, b.fecha_apertura, b.dealer_id, b.material_id,
    d.tarifa_hora_usd,
    (coalesce(m.proveedor, 'Sin Proveedor') = 'Nippon Parts'
      AND b.fecha_apertura BETWEEN DATE'2026-03-02' AND DATE'2026-04-17') AS en_incidente,
    pmod(hash(b.n, 'esp'), 100) AS r_espera
  FROM base b
  JOIN inchcape_workshop.ops.dim_material m ON m.material_id = b.material_id
  JOIN inchcape_workshop.ops.dim_dealer d ON d.dealer_id = b.dealer_id
),
calc AS (
  SELECT
    e.*,
    CAST(1.5 + pmod(hash(e.n, 'hb'), 14) * 0.5 AS DECIMAL(6, 2)) AS horas_bahia,
    CASE
      WHEN e.en_incidente AND e.r_espera < 85 THEN CAST(24 + pmod(hash(e.n, 'he'), 120) AS DECIMAL(6, 2))
      WHEN e.r_espera < 12 THEN CAST(4 + pmod(hash(e.n, 'he'), 20) AS DECIMAL(6, 2))
      ELSE CAST(0 AS DECIMAL(6, 2))
    END AS horas_espera_repuesto
  FROM enr e
)
SELECT
  concat('WO-', lpad(CAST(n AS STRING), 6, '0')),
  fecha_apertura,
  CASE WHEN horas_espera_repuesto > 100 THEN NULL
       ELSE date_add(fecha_apertura, 1 + CAST(horas_espera_repuesto / 12 AS INT)) END,
  dealer_id,
  material_id,
  CASE WHEN horas_espera_repuesto > 100 THEN 'Esperando Repuesto'
       WHEN pmod(hash(n, 'est'), 100) < 3 THEN 'En Proceso'
       ELSE 'Cerrada' END,
  horas_bahia,
  horas_espera_repuesto,
  CAST(round(horas_bahia * tarifa_hora_usd, 2) AS DECIMAL(10, 2)),
  CAST(round((40 + pmod(hash(n, 'rep'), 700)) * 1.0, 2) AS DECIMAL(10, 2)),
  CAST(round(horas_espera_repuesto * tarifa_hora_usd * 0.35, 2) AS DECIMAL(10, 2)),
  horas_espera_repuesto <= 24
FROM calc;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 7. `pmo.pmo_projects`: el portafolio de la PMO
-- MAGIC
-- MAGIC Los proyectos que la PMO abrió para arreglar el problema de posventa.
-- MAGIC Igual que en la vida real: nombres duplicados, fechas en blanco y presupuestos pasados.

-- COMMAND ----------

CREATE OR REPLACE TABLE inchcape_workshop.pmo.pmo_projects (
  proyecto_id     STRING        COMMENT 'Código del proyecto. Formato PRJ-001.',
  nombre          STRING        COMMENT 'Nombre del proyecto. Cuidado: hay nombres repetidos con proyecto_id distinto, o sea el mismo proyecto cargado dos veces.',
  programa        STRING        COMMENT 'Programa al que pertenece: Plan Posventa 360, Data y Analítica o Digital Retail.',
  lider           STRING        COMMENT 'Persona responsable del proyecto.',
  pais            STRING        COMMENT 'País donde se ejecuta: Colombia, Perú, Chile o Regional.',
  estado          STRING        COMMENT 'Estado reportado: En Curso, En Riesgo, Atrasado o Cerrado.',
  fecha_inicio    DATE          COMMENT 'Fecha de inicio del proyecto.',
  fecha_fin_plan  DATE          COMMENT 'Fecha de cierre comprometida. Puede venir en NULL cuando el proyecto se cargó sin planificar.',
  fecha_fin_real  DATE          COMMENT 'Fecha de cierre real. NULL si el proyecto sigue abierto.',
  presupuesto_usd DECIMAL(12,2) COMMENT 'Presupuesto aprobado en USD.',
  ejecutado_usd   DECIMAL(12,2) COMMENT 'Gasto ejecutado en USD. Puede superar el presupuesto aprobado.',
  avance_pct      INT           COMMENT 'Avance reportado por el líder, en porcentaje.',
  prioridad       STRING        COMMENT 'Prioridad: Alta, Media o Baja.'
)
COMMENT 'Portafolio de proyectos de la PMO de Inchcape Andina. 25 proyectos. Contiene defectos intencionales: nombres duplicados con código distinto, fechas comprometidas en NULL y proyectos con gasto por encima del presupuesto.'
TBLPROPERTIES ('capa' = 'gold', 'dominio' = 'pmo');

-- COMMAND ----------

INSERT INTO inchcape_workshop.pmo.pmo_projects
WITH nombres AS (
  SELECT array(
    'Plan Posventa 360 - Diagnóstico',
    'Reabastecimiento Inteligente de Repuestos',
    'Maestro de Materiales Único',
    'Torre de Control de Inventario',
    'Automatización de Reportes SAP',
    'Migración WEBI a AI/BI',
    'Data Products de Posventa',
    'Pronóstico de Demanda de Repuestos',
    'Portal de Repuestos para Concesionarios',
    'Alertas de Quiebre de Stock',
    'Gobierno de Datos con Unity Catalog',
    'Integración Proveedores Tier 1',
    'Optimización de Lead Time',
    'Tablero Ejecutivo de Posventa',
    'Calidad de Datos de Materiales',
    'Autoservicio Analítico para la PMO',
    'Modernización de Extracción SAP',
    'Medallion para Ventas de Repuestos',
    'Agente de Estatus de Proyectos',
    'Catálogo Interno de Datos',
    'Digitalización de Órdenes de Taller',
    'Control de Presupuesto de Programas',
    'Automatización de Reportes SAP',
    'Alertas de Quiebre de Stock',
    'Data Products de Posventa'
  ) AS arr
),
base AS (
  SELECT id AS n, pmod(hash(id, 'pres'), 100) AS r_pres FROM range(1, 26)
)
SELECT
  concat('PRJ-', lpad(CAST(b.n AS STRING), 3, '0')),
  element_at(nm.arr, CAST(b.n AS INT)),
  CASE WHEN b.n <= 14 THEN 'Plan Posventa 360' WHEN b.n <= 21 THEN 'Data y Analítica' ELSE 'Digital Retail' END,
  element_at(array('Herson Mesa', 'Erik López', 'Carolina Ruiz', 'Andrés Peña', 'Valentina Ríos', 'Diego Salas', 'Mariana Toro'), pmod(hash(b.n, 'lider'), 7) + 1),
  element_at(array('Colombia', 'Perú', 'Chile', 'Regional'), pmod(hash(b.n, 'pais'), 4) + 1),
  element_at(array('En Curso', 'En Curso', 'En Riesgo', 'Atrasado', 'Cerrado'), pmod(hash(b.n, 'est'), 5) + 1),
  date_add(DATE'2025-09-01', pmod(hash(b.n, 'ini'), 210)),
  -- Dos proyectos se cargaron sin fecha comprometida
  CASE WHEN b.n IN (7, 19) THEN NULL
       ELSE date_add(date_add(DATE'2025-09-01', pmod(hash(b.n, 'ini'), 210)), 90 + pmod(hash(b.n, 'dur'), 240)) END,
  CASE WHEN element_at(array('En Curso', 'En Curso', 'En Riesgo', 'Atrasado', 'Cerrado'), pmod(hash(b.n, 'est'), 5) + 1) = 'Cerrado'
       THEN date_add(date_add(DATE'2025-09-01', pmod(hash(b.n, 'ini'), 210)), 90 + pmod(hash(b.n, 'dur'), 240) + pmod(hash(b.n, 'atraso'), 60))
       ELSE NULL END,
  CAST(40000 + pmod(hash(b.n, 'ppto'), 460) * 1000 AS DECIMAL(12, 2)),
  -- Un tercio del portafolio va por encima del presupuesto aprobado
  CASE WHEN b.r_pres < 32
       THEN CAST(round((40000 + pmod(hash(b.n, 'ppto'), 460) * 1000) * (1.05 + pmod(hash(b.n, 'over'), 40) / 100.0), 2) AS DECIMAL(12, 2))
       ELSE CAST(round((40000 + pmod(hash(b.n, 'ppto'), 460) * 1000) * (0.35 + pmod(hash(b.n, 'under'), 60) / 100.0), 2) AS DECIMAL(12, 2)) END,
  pmod(hash(b.n, 'av'), 101),
  element_at(array('Alta', 'Alta', 'Media', 'Baja'), pmod(hash(b.n, 'prio'), 4) + 1)
FROM base b
CROSS JOIN nombres nm;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 8. `pmo.pmo_milestones`: los hitos

-- COMMAND ----------

CREATE OR REPLACE TABLE inchcape_workshop.pmo.pmo_milestones (
  hito_id       STRING  COMMENT 'Código del hito. Formato HITO-0001.',
  proyecto_id   STRING  COMMENT 'Proyecto al que pertenece el hito. Se une con pmo.pmo_projects.',
  nombre        STRING  COMMENT 'Nombre del hito.',
  fecha_plan    DATE    COMMENT 'Fecha comprometida del hito.',
  fecha_real    DATE    COMMENT 'Fecha real de cumplimiento. NULL si el hito no se ha cumplido.',
  estado        STRING  COMMENT 'Estado del hito: Cumplido, Pendiente o Vencido.',
  responsable   STRING  COMMENT 'Persona responsable del hito.'
)
COMMENT 'Hitos de los proyectos de la PMO. Seis hitos por proyecto. La diferencia entre fecha_plan y fecha_real es el deslizamiento del proyecto.'
TBLPROPERTIES ('capa' = 'gold', 'dominio' = 'pmo');

-- COMMAND ----------

INSERT INTO inchcape_workshop.pmo.pmo_milestones
WITH cruce AS (
  SELECT p.proyecto_id, p.fecha_inicio, h.id AS k,
         pmod(hash(p.proyecto_id, h.id, 'st'), 100) AS r
  FROM inchcape_workshop.pmo.pmo_projects p
  CROSS JOIN range(1, 7) h
)
SELECT
  concat('HITO-', lpad(CAST(row_number() OVER (ORDER BY proyecto_id, k) AS STRING), 4, '0')),
  proyecto_id,
  element_at(array('Kickoff', 'Levantamiento de requerimientos', 'Diseño de solución', 'Construcción', 'Pruebas con usuario', 'Puesta en producción'), CAST(k AS INT)),
  date_add(fecha_inicio, CAST(k AS INT) * 35),
  CASE WHEN r < 62 THEN date_add(fecha_inicio, CAST(k AS INT) * 35 + pmod(hash(proyecto_id, k, 'dias'), 40) - 8) ELSE NULL END,
  CASE WHEN r < 62 THEN 'Cumplido'
       WHEN date_add(fecha_inicio, CAST(k AS INT) * 35) < DATE'2026-08-12' THEN 'Vencido'
       ELSE 'Pendiente' END,
  element_at(array('Herson Mesa', 'Erik López', 'Carolina Ruiz', 'Andrés Peña', 'Valentina Ríos', 'Diego Salas', 'Mariana Toro'), pmod(hash(proyecto_id, k, 'resp'), 7) + 1)
FROM cruce;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 9. `pmo.pmo_budget`: el presupuesto mes a mes

-- COMMAND ----------

CREATE OR REPLACE TABLE inchcape_workshop.pmo.pmo_budget (
  linea_id            STRING        COMMENT 'Código de la línea de presupuesto.',
  proyecto_id         STRING        COMMENT 'Proyecto al que pertenece la línea. Se une con pmo.pmo_projects.',
  mes                 DATE          COMMENT 'Primer día del mes al que corresponde la línea.',
  categoria           STRING        COMMENT 'Categoría del gasto: Licencias, Servicios, Personal o Infraestructura.',
  presupuesto_mes_usd DECIMAL(12,2) COMMENT 'Presupuesto asignado al mes, en USD.',
  ejecutado_mes_usd   DECIMAL(12,2) COMMENT 'Gasto ejecutado en el mes, en USD.'
)
COMMENT 'Presupuesto mensual por proyecto y categoría de gasto. Comparar presupuesto contra ejecutado es el cruce que la PMO hace antes de cada reporte oficial.'
TBLPROPERTIES ('capa' = 'gold', 'dominio' = 'pmo');

-- COMMAND ----------

INSERT INTO inchcape_workshop.pmo.pmo_budget
WITH meses AS (
  SELECT explode(sequence(DATE'2025-09-01', DATE'2026-08-01', INTERVAL 1 MONTH)) AS mes
),
cruce AS (
  SELECT p.proyecto_id, p.presupuesto_usd, m.mes,
         pmod(hash(p.proyecto_id, m.mes, 'cat'), 4) + 1 AS idx_cat,
         pmod(hash(p.proyecto_id, m.mes, 'eje'), 100) AS r
  FROM inchcape_workshop.pmo.pmo_projects p
  CROSS JOIN meses m
)
SELECT
  concat('BL-', lpad(CAST(row_number() OVER (ORDER BY proyecto_id, mes) AS STRING), 5, '0')),
  proyecto_id,
  mes,
  element_at(array('Licencias', 'Servicios', 'Personal', 'Infraestructura'), idx_cat),
  CAST(round(presupuesto_usd / 12, 2) AS DECIMAL(12, 2)),
  CAST(round(presupuesto_usd / 12 * (0.4 + r / 100.0), 2) AS DECIMAL(12, 2))
FROM cruce;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 10. `raw.sap_mara` y `raw.sap_vbap`: los extractos crudos de SAP
-- MAGIC
-- MAGIC Así llega la data del origen: fechas como texto, códigos con ceros a la izquierda,
-- MAGIC espacios de más, decimales con coma y filas repetidas. Sin limpiar.

-- COMMAND ----------

CREATE OR REPLACE TABLE inchcape_workshop.raw.sap_mara (
  MANDT STRING COMMENT 'Mandante SAP. Siempre 800.',
  MATNR STRING COMMENT 'Número de material con ceros a la izquierda, 18 posiciones. Hay valores repetidos.',
  MAKTX STRING COMMENT 'Descripción del material. Trae espacios sobrantes al inicio o al final.',
  MTART STRING COMMENT 'Tipo de material.',
  MATKL STRING COMMENT 'Grupo de artículos, en código.',
  MEINS STRING COMMENT 'Unidad de medida base.',
  LIFNR STRING COMMENT 'Proveedor. Puede venir vacío.',
  PREIS STRING COMMENT 'Precio como texto. Algunos registros usan coma como separador decimal.',
  ERSDA STRING COMMENT 'Fecha de creación en formato AAAAMMDD, como texto.',
  LAEDA STRING COMMENT 'Fecha de última modificación en formato AAAAMMDD, como texto.',
  LVORM STRING COMMENT 'Marca de borrado. X si el registro está marcado para borrar.'
)
COMMENT 'Extracto crudo del maestro de materiales de SAP, tabla MARA. Sin limpiar: fechas como texto, ceros a la izquierda, espacios sobrantes, decimales con coma y registros duplicados.'
TBLPROPERTIES ('capa' = 'bronze', 'origen' = 'SAP ECC', 'dominio' = 'posventa');

-- COMMAND ----------

INSERT INTO inchcape_workshop.raw.sap_mara
WITH src AS (
  SELECT m.*, CAST(regexp_replace(m.material_id, 'MAT-', '') AS INT) AS idx
  FROM inchcape_workshop.ops.dim_material m
),
-- 30 registros se extraen dos veces: el mismo MATNR llega repetido
dups AS (
  SELECT s.* FROM src s WHERE s.idx <= 30
),
todos AS (
  SELECT * FROM src UNION ALL SELECT * FROM dups
)
SELECT
  '800',
  lpad(CAST(idx AS STRING), 18, '0'),
  CASE
    WHEN pmod(hash(idx, 'sp'), 5) = 0 THEN concat('  ', material_desc)
    WHEN pmod(hash(idx, 'sp'), 5) = 1 THEN concat(material_desc, '   ')
    ELSE material_desc
  END,
  CASE WHEN es_alta_rotacion THEN 'HAWA' ELSE 'HALB' END,
  concat('GRP', lpad(CAST(pmod(hash(familia, 'g'), 10) + 1 AS STRING), 2, '0')),
  element_at(array('PC', 'EA', 'L', 'KG'), pmod(hash(idx, 'me'), 4) + 1),
  coalesce(concat('PROV', lpad(CAST(pmod(hash(proveedor, 'p'), 8) + 1 AS STRING), 3, '0')), ''),
  CASE
    WHEN pmod(hash(idx, 'com'), 6) = 0 THEN replace(CAST(precio_lista_usd AS STRING), '.', ',')
    ELSE CAST(precio_lista_usd AS STRING)
  END,
  date_format(date_add(DATE'2018-01-01', pmod(hash(idx, 'ers'), 2500)), 'yyyyMMdd'),
  date_format(date_add(DATE'2025-06-01', pmod(hash(idx, 'lae'), 420)), 'yyyyMMdd'),
  CASE WHEN pmod(hash(idx, 'lv'), 50) = 0 THEN 'X' ELSE '' END
FROM todos;

-- COMMAND ----------

CREATE OR REPLACE TABLE inchcape_workshop.raw.sap_vbap (
  MANDT  STRING COMMENT 'Mandante SAP. Siempre 800.',
  VBELN  STRING COMMENT 'Número de documento de venta, con ceros a la izquierda.',
  POSNR  STRING COMMENT 'Número de posición dentro del documento.',
  MATNR  STRING COMMENT 'Número de material con ceros a la izquierda. Puede venir vacío.',
  WERKS  STRING COMMENT 'Centro que despacha.',
  KWMENG STRING COMMENT 'Cantidad pedida, como texto.',
  NETWR  STRING COMMENT 'Valor neto de la posición, como texto. Algunos registros usan coma decimal y unos pocos vienen en negativo.',
  WAERK  STRING COMMENT 'Moneda del documento.',
  ERDAT  STRING COMMENT 'Fecha de creación en formato AAAAMMDD, como texto.'
)
COMMENT 'Extracto crudo de posiciones de documento de venta de SAP, tabla VBAP. Sin limpiar: cantidades y valores como texto, decimales con coma, materiales vacíos y valores negativos.'
TBLPROPERTIES ('capa' = 'bronze', 'origen' = 'SAP ECC', 'dominio' = 'posventa');

-- COMMAND ----------

INSERT INTO inchcape_workshop.raw.sap_vbap
WITH src AS (
  SELECT
    v.venta_id, v.fecha, v.material_id, v.cantidad, v.monto_usd, v.dealer_id,
    CAST(regexp_replace(v.venta_id, 'SO-', '') AS INT) AS idx
  FROM inchcape_workshop.ops.fact_parts_sales v
  WHERE pmod(hash(v.venta_id, 'muestra'), 4) = 0
)
SELECT
  '800',
  lpad(CAST(4000000 + idx AS STRING), 10, '0'),
  lpad(CAST(pmod(hash(idx, 'pos'), 9) * 10 + 10 AS STRING), 6, '0'),
  CASE WHEN pmod(hash(idx, 'nul'), 200) = 0 THEN ''
       ELSE lpad(regexp_replace(material_id, 'MAT-', ''), 18, '0') END,
  concat('C', lpad(regexp_replace(dealer_id, 'D', ''), 3, '0')),
  CAST(cantidad AS STRING),
  CASE
    WHEN pmod(hash(idx, 'neg'), 150) = 0 THEN concat('-', CAST(monto_usd AS STRING))
    WHEN pmod(hash(idx, 'com'), 6) = 0 THEN replace(CAST(monto_usd AS STRING), '.', ',')
    ELSE CAST(monto_usd AS STRING)
  END,
  'USD',
  date_format(fecha, 'yyyyMMdd')
FROM src;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 11. Validación
-- MAGIC
-- MAGIC Si esta celda corre y ves las 11 tablas con filas, el setup quedó listo.

-- COMMAND ----------

SELECT 'ops.dim_dealer' AS tabla, count(*) AS filas FROM inchcape_workshop.ops.dim_dealer
UNION ALL SELECT 'ops.dim_material', count(*) FROM inchcape_workshop.ops.dim_material
UNION ALL SELECT 'ops.fact_supply_incident', count(*) FROM inchcape_workshop.ops.fact_supply_incident
UNION ALL SELECT 'ops.fact_parts_sales', count(*) FROM inchcape_workshop.ops.fact_parts_sales
UNION ALL SELECT 'ops.fact_stock', count(*) FROM inchcape_workshop.ops.fact_stock
UNION ALL SELECT 'ops.fact_workorder', count(*) FROM inchcape_workshop.ops.fact_workorder
UNION ALL SELECT 'pmo.pmo_projects', count(*) FROM inchcape_workshop.pmo.pmo_projects
UNION ALL SELECT 'pmo.pmo_milestones', count(*) FROM inchcape_workshop.pmo.pmo_milestones
UNION ALL SELECT 'pmo.pmo_budget', count(*) FROM inchcape_workshop.pmo.pmo_budget
UNION ALL SELECT 'raw.sap_mara', count(*) FROM inchcape_workshop.raw.sap_mara
UNION ALL SELECT 'raw.sap_vbap', count(*) FROM inchcape_workshop.raw.sap_vbap
ORDER BY tabla;
