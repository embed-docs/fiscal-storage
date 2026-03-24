# EMBED Storage API — Guia de Integracao

## Introducao

A **EMBED Storage API** permite o envio de documentos fiscais eletronicos brasileiros para armazenamento seguro e processamento na plataforma EMBED.

Com uma unica chamada HTTP, voce envia o XML do documento fiscal e a plataforma cuida do armazenamento, classificacao e disponibilizacao dos dados no painel de gestao.

Para mais informacoes sobre a plataforma, acesse [www.embed.it](https://www.embed.it).

---

## Obtendo sua Chave de Acesso

Para utilizar a API, voce precisa de uma chave de autenticacao (`API Key`). Entre em contato com nosso time comercial para obter a sua:

**E-mail:** [comercial@embed.it](mailto:comercial@embed.it)
**Site:** [www.embed.it](https://www.embed.it)

---

## Endpoint

| Ambiente | URL Base |
|----------|----------|
| Homologacao | `https://storage-api.embed.zone` |
| Producao | `https://storage-api.embed.it` |

---

## Autenticacao

Todas as requisicoes devem incluir o header `X-Api-Key` com a chave fornecida pela EMBED.

```
X-Api-Key: emb_sua_chave_aqui
```

- A chave tem o formato `emb_` seguido de 64 caracteres hexadecimais
- Cada chave esta vinculada a sua empresa
- **Nunca compartilhe sua chave.** Em caso de vazamento, solicite revogacao imediata pelo e-mail [comercial@embed.it](mailto:comercial@embed.it)

---

## Versionamento

A API utiliza versionamento no path. Utilize sempre o prefixo `/v1/` nas suas chamadas.

```
POST https://storage-api.embed.it/v1/ingest
```

**Garantias de compatibilidade:**
- Campos existentes no response nunca serao removidos nem terao seu significado alterado
- Novos campos opcionais podem ser adicionados ao response
- Mudancas que quebrem compatibilidade serao lancadas em uma nova versao (ex: `/v2/`), mantendo a versao anterior ativa

---

## Enviando Documentos

### POST /v1/ingest

Envia um documento fiscal XML para a plataforma.

**Headers:**

| Header | Obrigatorio | Descricao |
|--------|-------------|-----------|
| `X-Api-Key` | Sim | Chave de autenticacao |
| `Content-Type` | Sim | `application/xml` ou `text/xml` |

**Query Parameters:**

| Parametro | Obrigatorio | Descricao |
|-----------|-------------|-----------|
| `filename` | Nao | Nome original do arquivo (ex: `nota_001.xml`). Se omitido, sera gerado automaticamente. |

**Body:**

O conteudo XML do documento fiscal, enviado diretamente no corpo da requisicao.

### Documentos Suportados

| Tipo | Descricao |
|------|-----------|
| **NF-e** | Nota Fiscal Eletronica (modelo 55) — versoes 2.00, 3.10 e 4.00 |
| **NFC-e** | Nota Fiscal de Consumidor Eletronica (modelo 65) — versoes 3.10 e 4.00 |
| **NFS-e** | Nota Fiscal de Servico Eletronica (padrao nacional SPED) |
| **Evento NF-e** | Cancelamento, carta de correcao, confirmacao, ciencia da operacao e outros eventos |
| **Inutilizacao NF-e** | Inutilizacao de numeracao de NF-e/NFC-e |

A API tambem aceita **qualquer outro documento XML fiscal** (ex: CT-e, MDF-e, SAT/CF-e, NF3e). Tipos ainda nao mapeados sao recebidos e armazenados com seguranca para processamento futuro.

> **Garantia de guarda:** Uma vez que a API retorne HTTP 200, o documento esta salvo e sua guarda e garantida, independente do tipo. Nao ha risco de perda.

**Formatos de envelope aceitos:**

- `<nfeProc>` contendo `<NFe>` + `<protNFe>` (formato completo)
- `<NFe>` diretamente (formato sem protocolo)
- Envelope SOAP contendo documentos fiscais

---

### Respostas da API

**Sucesso (HTTP 200):**

```json
{
    "filename": "nota_001.xml",
    "hash": "471ee1f2a2e89e8961b389e1925369c763ae97364e0b5b70ccdebc888019dada",
    "message": "Documento recebido com sucesso"
}
```

| Campo | Descricao |
|-------|-----------|
| `filename` | Nome do arquivo registrado |
| `hash` | SHA-256 do documento — identificador unico do envio |
| `message` | Confirmacao de recebimento |

**Erro de validacao (HTTP 400):**

```json
{
    "error": "Body vazio — envie o XML no corpo da requisição"
}
```

**Autenticacao invalida (HTTP 401):**

```json
{
    "message": "Unauthorized"
}
```

**Erro interno (HTTP 500):**

```json
{
    "error": "Falha ao salvar arquivo no repositório"
}
```

---

### Verificacao de Disponibilidade

**GET /v1/health**

Verifica se a API esta disponivel. Nao requer autenticacao.

```json
{
    "status": "ok"
}
```

---

## Exemplos de Integracao

### cURL

```bash
curl -X POST "https://storage-api.embed.it/v1/ingest?filename=nota_001.xml" \
  -H "X-Api-Key: emb_sua_chave_aqui" \
  -H "Content-Type: application/xml" \
  --data-binary @/caminho/para/nota_fiscal.xml
```

### Python

```python
import requests

API_URL = "https://storage-api.embed.it/v1/ingest"
API_KEY = "emb_sua_chave_aqui"

with open("nota_fiscal.xml", "rb") as f:
    xml_bytes = f.read()

response = requests.post(
    API_URL,
    params={"filename": "nota_fiscal.xml"},
    headers={
        "X-Api-Key": API_KEY,
        "Content-Type": "application/xml",
    },
    data=xml_bytes,
)

if response.status_code == 200:
    data = response.json()
    print(f"Enviado com sucesso. Hash: {data['hash']}")
else:
    print(f"Erro {response.status_code}: {response.text}")
```

### JavaScript (Node.js)

```javascript
const fs = require('fs');
const https = require('https');
const url = require('url');

const API_URL = 'https://storage-api.embed.it/v1/ingest';
const API_KEY = 'emb_sua_chave_aqui';
const filePath = 'nota_fiscal.xml';

const xmlBytes = fs.readFileSync(filePath);
const filename = encodeURIComponent(filePath.split('/').pop());

const parsed = new URL(`${API_URL}?filename=${filename}`);

const options = {
    hostname: parsed.hostname,
    path: parsed.pathname + parsed.search,
    method: 'POST',
    headers: {
        'X-Api-Key': API_KEY,
        'Content-Type': 'application/xml',
        'Content-Length': xmlBytes.length,
    },
};

const req = https.request(options, (res) => {
    let body = '';
    res.on('data', (chunk) => (body += chunk));
    res.on('end', () => {
        if (res.statusCode === 200) {
            const data = JSON.parse(body);
            console.log(`Enviado com sucesso. Hash: ${data.hash}`);
        } else {
            console.log(`Erro ${res.statusCode}: ${body}`);
        }
    });
});

req.write(xmlBytes);
req.end();
```

### JavaScript (Fetch API — Browser/Deno)

```javascript
const API_URL = 'https://storage-api.embed.it/v1/ingest';
const API_KEY = 'emb_sua_chave_aqui';

async function enviarXml(xmlContent, filename) {
    const response = await fetch(
        `${API_URL}?filename=${encodeURIComponent(filename)}`,
        {
            method: 'POST',
            headers: {
                'X-Api-Key': API_KEY,
                'Content-Type': 'application/xml',
            },
            body: xmlContent,
        }
    );

    const data = await response.json();

    if (response.ok) {
        console.log(`Enviado com sucesso. Hash: ${data.hash}`);
    } else {
        console.log(`Erro ${response.status}: ${data.error || data.message}`);
    }

    return data;
}
```

### PHP

```php
<?php
$apiUrl = "https://storage-api.embed.it/v1/ingest";
$apiKey = "emb_sua_chave_aqui";
$xmlPath = "/caminho/para/nota_fiscal.xml";

$xmlContent = file_get_contents($xmlPath);
$filename = basename($xmlPath);

$ch = curl_init();
curl_setopt_array($ch, [
    CURLOPT_URL            => $apiUrl . "?filename=" . urlencode($filename),
    CURLOPT_POST           => true,
    CURLOPT_POSTFIELDS     => $xmlContent,
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_HTTPHEADER     => [
        "X-Api-Key: " . $apiKey,
        "Content-Type: application/xml",
    ],
]);

$response = curl_exec($ch);
$httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
curl_close($ch);

if ($httpCode === 200) {
    $data = json_decode($response, true);
    echo "Enviado com sucesso. Hash: " . $data['hash'] . "\n";
} else {
    echo "Erro {$httpCode}: {$response}\n";
}
```

### C# (.NET)

```csharp
using System.Net.Http;

var apiUrl = "https://storage-api.embed.it/v1/ingest";
var apiKey = "emb_sua_chave_aqui";

var xmlContent = File.ReadAllBytes("nota_fiscal.xml");

using var client = new HttpClient();
client.DefaultRequestHeaders.Add("X-Api-Key", apiKey);

var content = new ByteArrayContent(xmlContent);
content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/xml");

var response = await client.PostAsync($"{apiUrl}?filename=nota_fiscal.xml", content);
var body = await response.Content.ReadAsStringAsync();

if (response.IsSuccessStatusCode)
    Console.WriteLine($"Sucesso: {body}");
else
    Console.WriteLine($"Erro {(int)response.StatusCode}: {body}");
```

### Java

```java
import java.net.URI;
import java.net.http.*;
import java.nio.file.*;

public class XmlIngestClient {
    public static void main(String[] args) throws Exception {
        String apiUrl = "https://storage-api.embed.it/v1/ingest";
        String apiKey = "emb_sua_chave_aqui";

        byte[] xmlBytes = Files.readAllBytes(Path.of("nota_fiscal.xml"));

        HttpRequest request = HttpRequest.newBuilder()
            .uri(URI.create(apiUrl + "?filename=nota_fiscal.xml"))
            .header("X-Api-Key", apiKey)
            .header("Content-Type", "application/xml")
            .POST(HttpRequest.BodyPublishers.ofByteArray(xmlBytes))
            .build();

        HttpClient client = HttpClient.newHttpClient();
        HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString());

        System.out.println("Status: " + response.statusCode());
        System.out.println("Body: " + response.body());
    }
}
```

### Delphi (12+)

```pascal
uses
  System.SysUtils, System.Classes, System.Net.HttpClient,
  System.Net.URLClient, System.Net.Mime;

procedure EnviarXml;
var
  HttpClient: THTTPClient;
  Response: IHTTPResponse;
  XmlStream: TFileStream;
  ApiUrl, ApiKey, FilePath: string;
  Headers: TNetHeaders;
begin
  ApiUrl := 'https://storage-api.embed.it/v1/ingest';
  ApiKey := 'emb_sua_chave_aqui';
  FilePath := 'C:\notas\nota_fiscal.xml';

  HttpClient := THTTPClient.Create;
  XmlStream := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyNone);
  try
    Headers := [
      TNameValuePair.Create('X-Api-Key', ApiKey),
      TNameValuePair.Create('Content-Type', 'application/xml')
    ];

    Response := HttpClient.Post(
      ApiUrl + '?filename=' + TNetEncoding.URL.Encode(ExtractFileName(FilePath)),
      XmlStream,
      nil,
      Headers
    );

    if Response.StatusCode = 200 then
      WriteLn('Enviado com sucesso: ' + Response.ContentAsString())
    else
      WriteLn(Format('Erro %d: %s', [Response.StatusCode, Response.ContentAsString()]));
  finally
    XmlStream.Free;
    HttpClient.Free;
  end;
end;
```

### Go

```go
package main

import (
    "bytes"
    "fmt"
    "io"
    "net/http"
    "net/url"
    "os"
)

func main() {
    apiURL := "https://storage-api.embed.it/v1/ingest"
    apiKey := "emb_sua_chave_aqui"
    filePath := "nota_fiscal.xml"

    xmlBytes, err := os.ReadFile(filePath)
    if err != nil {
        fmt.Printf("Erro ao ler arquivo: %v\n", err)
        return
    }

    reqURL := fmt.Sprintf("%s?filename=%s", apiURL, url.QueryEscape(filePath))
    req, _ := http.NewRequest("POST", reqURL, bytes.NewReader(xmlBytes))
    req.Header.Set("X-Api-Key", apiKey)
    req.Header.Set("Content-Type", "application/xml")

    resp, err := http.DefaultClient.Do(req)
    if err != nil {
        fmt.Printf("Erro na requisicao: %v\n", err)
        return
    }
    defer resp.Body.Close()

    body, _ := io.ReadAll(resp.Body)

    if resp.StatusCode == 200 {
        fmt.Printf("Enviado com sucesso: %s\n", body)
    } else {
        fmt.Printf("Erro %d: %s\n", resp.StatusCode, body)
    }
}
```

---

## Envio em Lote

Para enviar multiplos documentos, faca uma requisicao `POST /v1/ingest` por arquivo.

**Recomendacoes:**

- Envie ate 10 requisicoes em paralelo para melhor desempenho
- Use o `hash` retornado para rastrear cada documento
- Documentos identicos (mesmo conteudo XML) serao aceitos sem erro e sem gerar duplicidade

### Scripts de Envio Massivo

Disponibilizamos scripts prontos para envio massivo de XMLs com paralelismo configuravel, retomada automatica e organizacao dos arquivos.

#### Linux/macOS (bash)

**Requisitos:** bash, curl, python3

```bash
./bulk-send.sh <sua_api_key> /caminho/para/xmls/
./bulk-send.sh <sua_api_key> /caminho/para/xmls/ --parallel 20 --verbose
./bulk-send.sh <sua_api_key> /caminho/para/xmls/ --recursive --organize
./bulk-send.sh <sua_api_key> /caminho/para/xmls/ --dry-run
```

#### Windows (PowerShell 7+)

```powershell
.\bulk-send.ps1 emb_sua_chave... C:\notas
.\bulk-send.ps1 emb_sua_chave... C:\notas -Parallel 20 -VerboseOutput
.\bulk-send.ps1 emb_sua_chave... C:\notas -Recursive -Organize
.\bulk-send.ps1 emb_sua_chave... C:\notas -DryRun
```

#### Opcoes disponiveis

| bash | PowerShell | Default | Descricao |
|------|------------|---------|-----------|
| `--parallel N` | `-Parallel N` | 10 | Numero de envios simultaneos |
| `--recursive` | `-Recursive` | — | Busca XMLs em subdiretorios |
| `--organize` | `-Organize` | — | Move XMLs processados para `processed/` e com erro para `errors/` |
| `--dry-run` | `-DryRun` | — | Lista os arquivos sem enviar |
| `--verbose` | `-VerboseOutput` | — | Mostra detalhes de cada envio |
| `--sent-log FILE` | `-SentLog FILE` | auto | Arquivo de controle para retomada automatica |

**Retomada automatica:** Se o envio for interrompido, basta executar o mesmo comando novamente. Arquivos ja enviados com sucesso serao pulados automaticamente.

**Organizacao (`--organize`):**

```
C:\notas\
  nota_001.xml              <- antes do envio
  nota_002.xml
  nota_003.xml

C:\notas\
  processed\                <- criada automaticamente
    nota_001.xml            <- envio OK
    nota_002.xml            <- envio OK
  errors\                   <- criada somente se houver erros
    nota_003.xml            <- envio falhou
```

Solicite os scripts pelo e-mail [comercial@embed.it](mailto:comercial@embed.it).

---

## Comportamento de Deduplicacao

A API e **idempotente** em relacao a documentos duplicados:

| Cenario | Comportamento |
|---------|---------------|
| Mesmo XML enviado mais de uma vez | Todos retornam `200`. Apenas 1 registro e criado. |
| XML com mesma chave de acesso | Registro existente e atualizado. |
| XML com mesmo numero/serie/CNPJ/data | Registro existente e atualizado. |

Voce pode reenviar documentos com seguranca, sem risco de duplicidade.

---

## Tabela de Erros

| HTTP | Significado | O que fazer |
|------|-------------|-------------|
| 200 | Documento recebido com sucesso | Nenhuma acao — sucesso |
| 400 | Corpo da requisicao vazio ou XML invalido | Verificar o conteudo enviado |
| 401 | Chave de API invalida ou ausente | Verificar o header `X-Api-Key` |
| 500 | Erro interno no servidor | Aguardar alguns segundos e tentar novamente |

---

## Boas Praticas

1. **Armazene o hash retornado.** Ele e o identificador unico do documento na plataforma e pode ser usado para rastreabilidade.

2. **Implemente retry com backoff.** Em caso de erro 500, aguarde alguns segundos e tente novamente. Reenviar o mesmo documento e seguro.

3. **Envie o XML completo.** Preferencialmente no formato `<nfeProc>` que inclui o protocolo de autorizacao (`nProt`). Isso garante que todos os campos sejam preenchidos.

4. **Nao modifique o XML.** Envie o documento exatamente como recebido da SEFAZ. Qualquer alteracao no conteudo gerara um hash diferente.

5. **Use HTTPS.** Todas as comunicacoes sao feitas via HTTPS.

6. **Proteja sua API key.** Nao inclua a chave em codigo-fonte versionado. Use variaveis de ambiente ou cofre de segredos.

---

## Limites

| Recurso | Limite |
|---------|--------|
| Tamanho maximo do XML | 6 MB |
| Requisicoes por segundo | Sem limite rigido (auto-scaling) |
| Timeout da requisicao | 30 segundos |
| Tipos de documentos aceitos | Qualquer XML fiscal valido |

---

## Suporte

| Canal | Contato |
|-------|---------|
| Comercial e chave de acesso | [comercial@embed.it](mailto:comercial@embed.it) |
| Site | [www.embed.it](https://www.embed.it) |
