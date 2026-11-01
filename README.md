# AirPlay Subtitle Bridge

Aplicación personal de iPhone/iPad para navegar automáticamente un catálogo de anime a través de tu bridge, elegir serie, episodio y servidor, y reproducirlo por AirPlay con subtítulos como pistas HLS reales.

```text
App iOS: buscar → serie → episodio → servidor
                       │
                       ▼
Bridge local: API pública del sitio → metadatos del reproductor → HLS + VTT
                       │
                       ▼
AVPlayer en iPhone/iPad ───────── AirPlay ─────────► TV
```

No se pega una URL HLS o VTT en la app. El bridge obtiene los metadatos de episodio y servidor usando las mismas solicitudes AJAX públicas que utiliza la página. Consulta los metadatos públicos del reproductor, descifra su fuente temporal y conserva en memoria el HLS y los VTT. Después sirve un manifiesto HLS que declara cada VTT como subtítulo para `AVPlayer`.

Las URLs de reproducción, tokens y subtítulos no se registran en disco, no se devuelven a la app y desaparecen al reiniciar el bridge.

## Requisitos del bridge

- Un equipo en la misma red que iPhone/iPad y TV: Windows, Linux, Mac o NAS compatible.
- Node.js 20 o posterior.
- Acceso a Internet desde el bridge.

## Instalar y ejecutar

En el equipo que actuará como bridge:

```sh
cd proxy
npm install
node server.mjs
```

El primer paso instala `cheerio`. No se necesita Chromium, Playwright, ni un perfil de Edge. Permite conexiones entrantes TCP al puerto `8787` en el firewall. Encuentra la IP LAN del equipo y úsala en la app, por ejemplo `http://192.168.1.20:8787`.

Comprueba que el servicio arrancó:

```sh
curl http://127.0.0.1:8787/health
```

Debe responder `{"ok":true}`.

## Registros del bridge

Al arrancar, es normal que sólo aparezca la línea de dirección: no hay actividad hasta que la app se conecte. Esta versión registra cada operación del catálogo, la carga de episodios, el conteo de servidores Sub/Dub, la resolución del reproductor y cualquier error, sin imprimir URLs temporales, tokens ni credenciales.

Después de pulsar **Probar conexión** en la app, la consola debe mostrar como mínimo:

```text
[bridge] GET /health
```

Si no aparece esa línea, el iPhone/iPad no está llegando al equipo del bridge: revisa la IP configurada, que ambos equipos estén en la misma red y que el firewall de Windows permita conexiones entrantes TCP al puerto `8787`. Reinicia `node server.mjs` después de actualizar el código para aplicar los nuevos registros.

## Uso en la app

1. Compila e instala la app iOS.
2. Abre **Configuración**, escribe una vez la dirección de tu bridge local y usa **Probar conexión**. La dirección queda guardada en el dispositivo.
3. En **Buscar**, busca por título y elige una serie y un episodio.
4. Elige una fuente desde las pestañas `Sub` o `Dub`. La predeterminada se cambia en **Configuración** y es `Sub` inicialmente.
5. Usa el botón AirPlay de los controles nativos. Las pistas que el reproductor publica como VTT se anuncian como subtítulos HLS.

La app conserva localmente las últimas 50 reproducciones: serie, carátula, episodio, servidor, fecha y segundo actual. **Continuar viendo** tiene su propia pestaña y el reproductor retoma desde el último segundo guardado. El historial se guarda sólo en `UserDefaults` del iPhone/iPad; no se transmite al bridge ni al sitio.

La primera reproducción de un servidor tarda sólo lo necesario para solicitar los metadatos públicos de la fuente. Las siguientes peticiones HLS de esa reproducción pasan por el bridge.

## API local

La app usa estas rutas locales; no necesitas llamarlas manualmente.

- `GET /api/search?q=titulo`
- `POST /api/series` con `{ "watchUrl": "…" }`
- `GET /api/series/:seriesKey/servers?episode=2`
- `POST /api/play` con `{ "seriesKey": "…", "episode": 2, "serverIndex": 0 }`

Las sesiones de serie caducan en 20 minutos. El bridge sólo acepta URLs `/watch/...` del origen configurado para el catálogo y no expone un proxy genérico para otros dominios.

## Compilar la app iOS sin Mac

El workflow [`.github/workflows/ios-build.yml`](.github/workflows/ios-build.yml) se ejecuta en macOS dentro de GitHub Actions. Sube esta carpeta a un repositorio GitHub y ejecuta **Actions → Build iOS app → Run workflow**. Genera el artefacto `AirPlaySubtitlePlayer-unsigned.ipa`.

El IPA no viene firmado, pero es el formato que espera ByteLoader. Descárgalo desde el artefacto de Actions, arrástralo a ByteLoader y éste lo firma e instala con tu Apple ID. Con una cuenta Apple gratuita, la firma normalmente se renueva cada siete días; ByteLoader puede renovarla mientras el iPhone y PC estén disponibles en la misma red. [Guía oficial de ByteLoader](https://byteloader.byteknotlabs.com/guide)

## Límites técnicos

- Si una fuente no entrega HLS y VTT, no podrá convertirse en subtítulos AirPlay por este bridge.
- No se admiten DRM, paywalls, login ni mecanismos de acceso que impidan al receptor AirPlay recuperar el manifiesto local.
- El TV debe poder alcanzar directamente la dirección IP y el puerto del bridge: AirPlay puede volver a pedir el manifiesto desde el receptor.
- Para pruebas, usa el bridge sólo en tu red privada. Si usas HTTP local, la app permite networking local mediante ATS; para una red no confiable, pon el bridge detrás de HTTPS con un certificado válido.
