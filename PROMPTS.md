# Prompts del recorrido de Data Science

Todos los prompts del taller, listos para copiar y pegar en Genie Code.

Dos reglas antes de usarlos:

1. **Leé la respuesta antes de correrla.** El valor del ejercicio está en revisar
   lo que Genie propuso, no en ejecutarlo a ciegas. En modelado, el error más caro
   es el que corre sin fallar.
2. **Cuando algo falle, pegá el error completo** y escribí `Corregí esto`. Es más
   rápido que arreglarlo a mano y deja la conversación como documentación.

## 1. Exploración

### 1.1 La serie de demanda

```
Trabajo con el catálogo inchcape_workshop. Quiero entender la demanda de repuestos
antes de modelarla. Escribime PySpark que construya la serie semanal de demanda
desde inchcape_workshop.ops.fact_parts_sales, agregada por semana y por familia de
repuesto de inchcape_workshop.ops.dim_material.

Después graficame la serie con matplotlib, con una banda sombreada que marque el
periodo del 2 de marzo al 17 de abril de 2026, y con una línea por familia.
Excluí las líneas con monto negativo, que son anulaciones.
```

### 1.2 Oferta contra demanda

```
Sospecho que la caída de marzo de 2026 es un problema de oferta y no de demanda.
Escribime una consulta que lo verifique: para cada semana, la demanda en unidades,
el porcentaje de combinaciones de punto y repuesto en quiebre de stock según
inchcape_workshop.ops.fact_stock, y las horas de espera promedio de
inchcape_workshop.ops.fact_workorder.

Si el quiebre de stock y las horas de espera suben en las mismas semanas en que
cae la venta, es oferta. Decime qué muestran los números y con qué correlación.
```

### 1.3 Descomposición del impacto

```
Ahora quiero saber dónde se concentró el impacto. Escribime una consulta que
compare el periodo del incidente, del 2 de marzo al 17 de abril de 2026, contra
la línea base del resto de los doce meses, abriendo por proveedor, familia de
repuesto y país. Para cada combinación: unidades del periodo, unidades esperadas
según la línea base semanal, diferencia y porcentaje.
Ordenado por la diferencia en unidades, de mayor a menor.
```

### 1.4 La decisión sobre el periodo anómalo

```
Voy a entrenar un modelo de pronóstico de demanda semanal con estos datos. El
periodo del 2 de marzo al 17 de abril de 2026 es una anomalía de oferta: la venta
cayó porque no había inventario, no porque no hubiera cliente.

Explicame las tres opciones de tratamiento, que son excluir el periodo, marcarlo
con una variable indicadora, o imputar la demanda no atendida. Para cada una:
qué supone, qué pierde, y en qué caso la elegirías. No elijas por mí, dame el
criterio para elegir yo.
```

## 2. Variables

### 2.1 La tabla de entrenamiento

```
Necesito la tabla de variables para un modelo de pronóstico de demanda semanal de
repuestos, con grano de semana por punto de red y por familia.

Fuentes: inchcape_workshop.ops.fact_parts_sales para la demanda,
inchcape_workshop.ops.dim_material para la familia y el proveedor,
inchcape_workshop.ops.dim_dealer para país, tipo de punto y bahías,
inchcape_workshop.ops.fact_stock para el quiebre de stock.

Variables:
- demanda_unidades como objetivo.
- Rezagos de demanda de 1, 2, 4 y 13 semanas.
- Media móvil y desviación estándar de 4 y 13 semanas.
- Tasa de quiebre de stock de la semana anterior para ese punto y esa familia.
- semana_del_anio y mes como categóricas, no como enteros.
- pais, tipo_punto y bahias del punto.
- es_periodo_incidente como bandera, verdadera entre el 2 de marzo y el 17 de
  abril de 2026.

REGLA CRÍTICA: ninguna variable puede usar información de la semana que se quiere
predecir ni de semanas posteriores. Todas las ventanas son estrictamente
anteriores. Usá window functions con el rango correcto y explicame en un comentario
por qué el rango que elegiste no filtra el futuro.

Escribila en inchcape_workshop.ml.features_demanda y al final dame el conteo de
filas y de columnas.
```

### 2.2 Control de fuga de información

```
Escribime una verificación explícita de que la tabla
inchcape_workshop.ml.features_demanda no tiene fuga de información. Quiero, para
una muestra de veinte filas, que me muestres la semana de la fila, el valor del
objetivo, y el valor de cada variable de ventana, junto con las semanas que
entraron en el cálculo de esa ventana. Si alguna ventana incluye la semana de la
fila o una posterior, marcalo en rojo en la salida.
```

### 2.3 Correlaciones y variables inútiles

```
Sobre inchcape_workshop.ml.features_demanda, dame la correlación de cada variable
numérica con el objetivo, y la correlación entre las variables numéricas entre sí.
Decime qué variables están tan correlacionadas entre ellas que una es redundante,
y cuáles no aportan nada al objetivo. Recomendame un subconjunto para arrancar y
explicame el criterio.
```

## 3. El modelo

### 3.1 Línea base y partición temporal

```
Voy a entrenar sobre inchcape_workshop.ml.features_demanda. Antes del modelo,
necesito la línea base y la partición.

1. Partición temporal, no aleatoria: entrenamiento hasta una fecha de corte,
   validación después. Elegí la fecha de corte de forma que la validación tenga
   entre ocho y trece semanas, y decime cuál elegiste y por qué.
2. Dos líneas base: repetir la demanda de la semana anterior, y la media de las
   últimas cuatro semanas.
3. Calculá MAE, RMSE y MAPE ponderado por volumen de las dos líneas base sobre la
   validación, y registralas en MLflow como dos corridas dentro del experimento
   /Users/<mi usuario>/inchcape_demanda.

Explicame por qué un train_test_split aleatorio estaría mal acá.
```

### 3.2 El modelo de árboles

```
Ahora el modelo. Usá solamente lo que ya viene en el runtime de ML: scikit-learn,
pandas, mlflow. No propongas pip install de nada.

- HistGradientBoostingRegressor de scikit-learn, con las categóricas codificadas
  con OneHotEncoder dentro de un Pipeline.
- Grilla chica de hiperparámetros: tres combinaciones, moviendo learning_rate y
  max_iter. Estoy en Free Edition con cuota diaria, así que no quiero una búsqueda
  grande.
- Autologging de MLflow activo, con una corrida anidada por combinación.
- La firma del modelo inferida con infer_signature sobre el conjunto de
  entrenamiento, y un ejemplo de entrada registrado.
- Las mismas tres métricas que las líneas base, para poder comparar en la misma
  tabla del experimento.
- Al final, una tabla que compare las dos líneas base y las tres corridas,
  ordenada por MAE.
```

### 3.3 Entender el modelo

```
Sobre la mejor corrida, dame la importancia de las variables por permutación
sobre el conjunto de validación, no la importancia interna del modelo, y explicame
la diferencia entre las dos en una frase.
Después mostrame los veinte casos de validación con mayor error absoluto, con sus
variables, y decime si tienen algo en común. Quiero saber dónde falla el modelo,
no solo cuánto.
```

### 3.4 Debuggear una corrida

```
Tengo dos corridas en el experimento y una tiene un MAE mucho peor que la otra.
Escribime el código que traiga las dos corridas con mlflow.search_runs, compare
sus parámetros lado a lado, y me muestre solo lo que difiere.
```

## 4. Registro en Unity Catalog

```
Quiero registrar la mejor corrida como modelo en Unity Catalog. Dame el código
completo:

1. mlflow.set_registry_uri apuntando a Unity Catalog.
2. Crear el esquema inchcape_workshop.ml si no existe.
3. Registrar el modelo como inchcape_workshop.ml.demanda_repuestos.
4. Escribir la descripción de la versión con el periodo de datos, el MAE en
   validación y la línea base que superó.
5. Asignarle el alias campeon a esa versión.
6. Al final, cargar el modelo por alias y predecir cinco filas, para probar que
   el alias funciona y que la firma acepta la entrada.

Explicame por qué el job de scoring debería apuntar al alias y no al número de
versión.
```

## 5. Scoring y Data Product

### 5.1 El notebook de scoring

```
Escribime el notebook de scoring. Tiene que:

1. Cargar inchcape_workshop.ml.demanda_repuestos por el alias campeon.
2. Armar las variables de la última semana disponible en
   inchcape_workshop.ml.features_demanda, con exactamente la misma lógica de
   ventanas que usé en entrenamiento. Si la lógica se duplica, decime cómo
   evitarlo.
3. Predecir un horizonte de cuatro semanas.
4. Escribir en inchcape_workshop.ml.prediccion_demanda con: fecha de la semana
   predicha, dealer_id, familia, demanda_predicha, la versión del modelo que la
   produjo, y el timestamp de la corrida.
5. Ser idempotente: si corre dos veces la misma semana, no duplica filas.

Al final, la consulta de control que verifica cantidad de filas y rango de fechas.
```

### 5.2 El Data Product

```
La tabla inchcape_workshop.ml.prediccion_demanda es lo que el negocio va a
consumir. Convertila en un Data Product:

1. COMMENT en la tabla y en cada columna. El de la tabla dice qué predice, con qué
   horizonte, con qué modelo, con qué frecuencia se refresca y cuál es su error
   esperado en unidades.
2. Etiquetas: dominio posventa, tipo prediccion, modelo demanda_repuestos,
   dueño data-science-andina, refresco semanal.
3. Los GRANT para que el equipo de negocio pueda leerla sin modificarla.
4. Una vista inchcape_workshop.ml.vw_riesgo_quiebre que cruce la predicción con el
   inventario actual y el punto de reorden, y liste las combinaciones de punto y
   repuesto con riesgo de quiebre en las próximas cuatro semanas. Esa vista es lo
   que de verdad le sirve al equipo de compras.
```

### 5.3 El job con el SDK

```
Estoy en Free Edition y no puedo desplegar Asset Bundles. Creame el job de
scoring con el SDK de Python de Databricks desde este mismo notebook.

- Una tarea, que corre el notebook de scoring del path que le paso.
- Cómputo serverless.
- Agenda semanal, lunes a las 6 de la mañana, en zona horaria America/Bogota,
  y que quede pausada al crearse.
- Notificación por correo al dueño cuando falle.
- Que sea idempotente: si el job con ese nombre ya existe, lo actualiza en vez de
  crear uno nuevo.
- Al final, imprimí la URL del job.

El SDK ya viene en el runtime y se autentica solo dentro del notebook, así que no
me pidas configurar tokens.
```

## 6. MLOps y CI/CD

### 6.1 Revisión del bundle

```
Revisá el archivo databricks.yml de este repositorio y decime, para el target dev
contra el target prod, qué cambia y por qué cada diferencia importa.
Después decime tres cosas que le faltan para un entorno de producción real de una
empresa como Inchcape.
```

### 6.2 El pipeline de CI/CD

```
Revisá ci/github-actions-deploy.yml y explicame el flujo completo: qué corre en
un pull request, qué corre al fusionar a main, y qué requiere aprobación manual.
Después decime qué secretos necesita configurados y qué pasa si falta uno.
```

### 6.3 Promoción de modelos

```
Quiero escribir la política de promoción de modelos de Inchcape. Ayudame a
redactarla: qué métrica de corte, contra qué línea base, quién aprueba, qué se
documenta, y qué se hace cuando un modelo en producción se degrada.
Corto, una página, en español, con nombres de rol y no de persona.
```
