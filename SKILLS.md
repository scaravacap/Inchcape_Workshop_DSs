# Instrucciones y skills: cómo hacer que Genie Code no te meta fuga de información

Genie Code escribe scikit-learn correcto. Lo que no sabe es que tus datos son una
serie de tiempo, que la partición no puede ser aleatoria, y que la media móvil no
puede incluir la semana que querés predecir. Eso se lo decís una vez y queda dicho
para todas las conversaciones.

Este archivo tiene tres bloques para copiar y pegar.

## 1. Instrucciones de workspace para Genie Code

Van en la configuración del workspace, en la sección de instrucciones del
asistente. Aplican a todo el código que Genie Code escriba para vos.

```text
# Taller Inchcape Andina, perfil Data Science

## Plataforma
Databricks Free Edition, cómputo serverless, sin GPU. Trabajá con lo que ya viene
en el runtime: mlflow, scikit-learn, pandas, numpy, pyspark, matplotlib. pip
install contra PyPI funciona, pero cada instalación cuesta tiempo de la cuota:
proponela solo cuando de verdad haga falta y decime por qué.

Hay una instalación que sí es obligatoria. El runtime trae MLflow 2.11, que no
puede registrar modelos en Unity Catalog porque falla al subir los artefactos.
Todo notebook que entrene, registre, cargue o sirva un modelo arranca con estas
dos líneas y nada de MLflow antes de ellas:

    %pip install --upgrade "mlflow[databricks]" "scikit-learn==1.5.2" --quiet
    %restart_python

La versión de scikit-learn va fijada y tiene que ser la misma en entrenamiento y
en scoring. El modelo se serializa con la versión que lo entrena, y el job puede
arrancar con un runtime distinto al del notebook interactivo; cuando eso pasa el
modelo no carga y el error habla de __pyx_unpickle o de tipos no confiables.
Por lo mismo, mlflow.sklearn.log_model va siempre con
serialization_format="cloudpickle".

Y en la primera celda de código, antes de set_experiment y de cualquier log_model:

    mlflow.set_registry_uri("databricks-uc")

Si set_registry_uri va después, el notebook falla con CONFIG_NOT_AVAILABLE porque
MLflow consulta una configuración de Spark bloqueada en serverless.

Dos cosas más de este entorno, para que no las propongas: las tablas de inferencia
de AI Gateway no están habilitadas, y la librería databricks-feature-engineering no
funciona acá por conflictos de dependencias. Una feature table se hace con SQL
nativo de Unity Catalog: tabla Delta con clave primaria declarada, comentarios y
etiquetas.

## Datos
Catálogo: inchcape_workshop
- ops: operación de posventa. dim_dealer, dim_material, fact_parts_sales,
  fact_stock, fact_workorder, fact_supply_incident.
- pmo: portafolio de proyectos.
- raw: extractos crudos de SAP.
- ml: mi capa de trabajo. Acá van features_demanda, prediccion_demanda y los
  modelos registrados.

## Reglas de series de tiempo, no negociables
- La partición de entrenamiento y validación es SIEMPRE temporal. Nunca
  train_test_split aleatorio, ni KFold, ni shuffle. Si necesito validación
  cruzada, es TimeSeriesSplit.
- Ninguna variable puede usar información de la fila que se predice ni de fechas
  posteriores. Todas las ventanas son estrictamente anteriores. Cuando escribas
  una window function, dejá un comentario que explique por qué el rango elegido no
  filtra el futuro.
- Todo modelo se compara contra una línea base ingenua: la demanda de la semana
  anterior y la media de las últimas cuatro semanas. Si el modelo no le gana a la
  línea base, ese es el resultado y hay que reportarlo, no esconderlo.
- Métrica principal MAE en unidades. MAPE solo ponderado por volumen, porque el
  porcentaje se distorsiona donde la demanda es cercana a cero.
- Las variables de calendario, como semana del año y mes, van como categóricas.
  Como enteros introducen un orden falso.

## Convenciones de código
- Siempre nombres de tres partes: catalogo.esquema.tabla.
- Los modelos se registran en Unity Catalog con nombre de tres partes, después de
  mlflow.set_registry_uri("databricks-uc").
- Todo modelo registrado lleva firma inferida con infer_signature y un ejemplo de
  entrada.
- El scoring carga el modelo por alias, nunca por número de versión. Lo mismo el
  endpoint de serving: se resuelve el alias a su versión al crearlo.
- Las tablas que produzco llevan COMMENT en la tabla y en cada columna, y
  etiquetas de dominio y dueño. Una tabla sin comentarios no sale de mi notebook.
- Las feature tables llevan clave primaria declarada, con las columnas de la
  clave en NOT NULL.
- HistGradientBoostingRegressor no acepta matriz dispersa: el OneHotEncoder va
  con sparse_output=False.
- Las transformaciones van dentro de un Pipeline de scikit-learn, no aplicadas a
  mano antes del fit. Si el preprocesamiento queda fuera del modelo, el scoring lo
  tiene que replicar y ahí se rompe.
- Nombres de columna en español, snake_case, sin tildes.
- Nunca escribas tokens ni credenciales. Dentro del notebook, el SDK y el cliente
  de Spark se autentican solos.

## Cómo quiero las respuestas
- Explicame en una línea qué hace el código antes de mostrarlo.
- Cuando una decisión sea metodológica y no técnica, señalámela y dame el criterio
  para decidir yo, en vez de elegir en silencio.
- Junto a cada tabla que produzcas, dame la consulta de control que verifica que
  quedó bien.
- Respondé en español.
```

## 2. Instrucciones del Genie Agent sobre el catálogo del taller

Van en la configuración del Genie Agent, sección **Instructions**. Este bloque es
opcional en el recorrido: el Paso 1 explora con Python en el notebook, y si
además querés hacerle preguntas a las tablas en español, creá un Genie Agent
sobre `inchcape_workshop` y pegale este texto.

```text
# Contexto de negocio: Inchcape Andina, posventa y repuestos

Somos Inchcape Andina. Distribuimos vehículos y repuestos en Colombia, Perú y
Chile a través de 120 puntos: concesionarios, talleres autorizados y puntos de
repuestos.

## Vocabulario del negocio
- "Bahía" es un puesto de trabajo del taller. La columna bahias de dim_dealer dice
  cuántas tiene cada punto. Una bahía parada no factura.
- "Hora de bahía" es la unidad de ingreso de mano de obra. Se valoriza con
  tarifa_hora_usd de dim_dealer.
- "Quiebre de stock" es cuando el inventario de un repuesto llega a cero en un
  punto. En fact_stock lo marca la columna en_quiebre.
- "Alta rotación" son los repuestos que concentran la mayor parte de la venta. En
  dim_material lo marca es_alta_rotacion.
- "Lead time" son los días entre el pedido al proveedor y la recepción.
- "Punto de reorden" es el nivel de inventario que debería disparar el pedido.

## Cómo medir
- La demanda se mide en unidades con la columna cantidad de fact_parts_sales. El
  monto en dólares es monto_usd y ya tiene el descuento aplicado.
- Las líneas con monto negativo son anulaciones. Excluilas de la demanda.
- El impacto en dinero de un quiebre de stock se mide con costo_espera_usd de
  fact_workorder.
- Todos los montos están en dólares estadounidenses.

## Advertencia sobre el periodo del incidente
Entre el 2 de marzo y el 17 de abril de 2026 hubo una interrupción de
abastecimiento del proveedor Nippon Parts, registrada en fact_supply_incident.
La caída de venta de ese periodo es falta de oferta, no falta de demanda. Cada vez
que alguien pida una tendencia, un promedio o una proyección que incluya ese
periodo, avisá que está contaminado y ofrecé el número con y sin él.

## Convenciones
- Respondé en español, en tono directo.
- Nombrá siempre las tablas con catálogo, esquema y tabla.
- Cuando un resultado dependa de datos con problemas de calidad, decilo junto con
  la respuesta.
```

## 3. La política de promoción de modelos

Este bloque no es para la IA: es la plantilla que se discute en el Paso 6 y que se
llevan para escribir la de Inchcape. El alias `@campeon` es un comando de una
línea que esconde una decisión de negocio, y sin esta política la toma quien
corrió el notebook.

```markdown
# Política de promoción de modelos, dominio posventa

## Qué se promueve
Código, no artefactos. El modelo se reentrena en cada ambiente con los datos de
ese ambiente. El registro de Unity Catalog de producción solo recibe modelos
entrenados por un job de producción.

## Criterio de corte
Un modelo candidato pasa a `@campeon` cuando:
- Supera a la línea base ingenua por al menos [X]% en MAE sobre la ventana de
  validación más reciente.
- Supera al campeón vigente en MAE, medido sobre la misma ventana.
- No degrada el error en ninguno de los tres países por más de [Y]%.

Un modelo que gana en el agregado y pierde en un país no se promueve sin decisión
explícita. El agregado esconde el daño local.

## Quién aprueba
- Propone: el científico de datos dueño del modelo.
- Aprueba: [rol, no persona].
- Informa: el equipo de compras de repuestos, que es quien consume la predicción.

## Qué se documenta en la versión
Periodo de datos de entrenamiento, MAE en validación, línea base superada,
variables usadas, y el tratamiento aplicado a periodos anómalos.

## Degradación en producción
Se revisa mensualmente el MAE realizado contra el de validación. Si se degrada más
de [Z]%, se dispara reentrenamiento. Si el reentrenamiento no lo recupera, se
vuelve a la línea base ingenua y se escala. Una predicción mala sin aviso es peor
que no tener predicción.
```

## Por qué esto importa más que el prompt

El prompt del Paso 2 es largo, pero fijate qué parte del trabajo hace: enumera las
variables. La regla que evita que el modelo salga inservible, que ninguna ventana
mire el futuro, ya venía en el bloque 1.

La prueba está en pedirle la tabla de variables antes de pegar el bloque y después.
Sin contexto te devuelve una media móvil centrada, que es exactamente la que filtra
el futuro, y un `train_test_split(shuffle=True)`. Las dos cosas dan métricas
excelentes en validación y un modelo que no sirve en producción.

Ese es el error que hoy encuentran ustedes en revisión, cuando lo encuentran.
