#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const projectRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const corpusRoot = join(projectRoot, 'tests', 'corpus');
const documentsRoot = join(corpusRoot, 'documents');
const expectedRoot = join(corpusRoot, 'expected');
mkdirSync(documentsRoot, { recursive: true });
mkdirSync(expectedRoot, { recursive: true });

const glyphs = {
  A: ['01110','10001','10001','11111','10001','10001','10001'],
  C: ['01111','10000','10000','10000','10000','10000','01111'],
  D: ['11110','10001','10001','10001','10001','10001','11110'],
  E: ['11111','10000','10000','11110','10000','10000','11111'],
  G: ['01111','10000','10000','10111','10001','10001','01111'],
  H: ['10001','10001','10001','11111','10001','10001','10001'],
  I: ['11111','00100','00100','00100','00100','00100','11111'],
  L: ['10000','10000','10000','10000','10000','10000','11111'],
  M: ['10001','11011','10101','10101','10001','10001','10001'],
  N: ['10001','11001','10101','10011','10001','10001','10001'],
  O: ['01110','10001','10001','10001','10001','10001','01110'],
  P: ['11110','10001','10001','11110','10000','10000','10000'],
  R: ['11110','10001','10001','11110','10100','10010','10001'],
  S: ['01111','10000','10000','01110','00001','00001','11110'],
  T: ['11111','00100','00100','00100','00100','00100','00100'],
  U: ['10001','10001','10001','10001','10001','10001','01110'],
  '1': ['00100','01100','00100','00100','00100','00100','01110'],
  ' ': ['00000','00000','00000','00000','00000','00000','00000'],
};

function raster(text, scale = 3) {
  const width = (text.length * 6 - 1) * scale;
  const height = 7 * scale;
  const pixels = Buffer.alloc(width * height, 255);
  for (let index = 0; index < text.length; index += 1) {
    const glyph = glyphs[text[index]] ?? glyphs[' '];
    for (let y = 0; y < 7; y += 1) {
      for (let x = 0; x < 5; x += 1) {
        if (glyph[y][x] === '1') {
          for (let dy = 0; dy < scale; dy += 1) {
            for (let dx = 0; dx < scale; dx += 1) {
              pixels[(y * scale + dy) * width + index * 6 * scale + x * scale + dx] = 0;
            }
          }
        }
      }
    }
  }
  return { width, height, pixels };
}

function escapePdf(text) {
  return text.replaceAll('\\', '\\\\').replaceAll('(', '\\(').replaceAll(')', '\\)');
}

function buildPdf({ pages, mode, rotate = false }) {
  const objects = [];
  const add = (body) => {
    objects.push(Buffer.isBuffer(body) ? body : Buffer.from(body, 'ascii'));
    return objects.length;
  };
  const catalog = add('');
  const pagesObject = add('');
  const font = mode === 'scanned' ? null : add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
  const pageObjects = [];

  for (let pageIndex = 0; pageIndex < pages.length; pageIndex += 1) {
    const text = pages[pageIndex];
    const scanned = mode === 'scanned' || mode === 'mixed';
    let image = null;
    let imageSize = null;
    if (scanned) {
      const bitmap = raster(text.toUpperCase().replace(/[^ACDEGHILMNOPRSTU1 ]/g, ' '));
      imageSize = bitmap;
      image = add(Buffer.concat([
        Buffer.from(`<< /Type /XObject /Subtype /Image /Width ${bitmap.width} /Height ${bitmap.height} /ColorSpace /DeviceGray /BitsPerComponent 8 /Length ${bitmap.pixels.length} >>\nstream\n`, 'ascii'),
        bitmap.pixels,
        Buffer.from('\nendstream', 'ascii'),
      ]));
    }
    const commands = [];
    if (mode !== 'scanned') {
      text.split('\n').forEach((line, index) => {
        commands.push(`BT /F1 ${index === 0 ? 15 : 12} Tf 72 ${720 - index * 40} Td (${escapePdf(line)}) Tj ET`);
      });
      if (mode === 'multicolumn') {
        commands.push(`BT /F1 12 Tf 310 680 Td (${escapePdf(`${text} COLUMN TWO`)}) Tj ET`);
      }
    }
    if (image) commands.push(`q ${imageSize.width} 0 0 ${imageSize.height} 72 560 cm /Im1 Do Q`);
    const streamBody = Buffer.from(commands.join('\n'), 'ascii');
    const content = add(Buffer.concat([
      Buffer.from(`<< /Length ${streamBody.length} >>\nstream\n`, 'ascii'),
      streamBody,
      Buffer.from('\nendstream', 'ascii'),
    ]));
    const resources = [font ? `/Font << /F1 ${font} 0 R >>` : '', image ? `/XObject << /Im1 ${image} 0 R >>` : '']
      .filter(Boolean)
      .join(' ');
    pageObjects.push(add(`<< /Type /Page /Parent ${pagesObject} 0 R /MediaBox [0 0 612 792]${rotate ? ' /Rotate 90' : ''} /Resources << ${resources} >> /Contents ${content} 0 R >>`));
  }

  objects[catalog - 1] = Buffer.from(`<< /Type /Catalog /Pages ${pagesObject} 0 R >>`, 'ascii');
  objects[pagesObject - 1] = Buffer.from(`<< /Type /Pages /Kids [${pageObjects.map((id) => `${id} 0 R`).join(' ')}] /Count ${pageObjects.length} >>`, 'ascii');
  const chunks = [Buffer.from('%PDF-1.4\n%LF01\n', 'ascii')];
  const offsets = [0];
  let offset = chunks[0].length;
  objects.forEach((body, index) => {
    offsets.push(offset);
    const object = Buffer.concat([Buffer.from(`${index + 1} 0 obj\n`, 'ascii'), body, Buffer.from('\nendobj\n', 'ascii')]);
    chunks.push(object);
    offset += object.length;
  });
  const xrefOffset = offset;
  const xref = [`xref\n0 ${objects.length + 1}\n`, '0000000000 65535 f\n'];
  for (const value of offsets.slice(1)) xref.push(`${String(value).padStart(10, '0')} 00000 n\n`);
  xref.push(`trailer\n<< /Size ${objects.length + 1} /Root ${catalog} 0 R >>\nstartxref\n${xrefOffset}\n%%EOF\n`);
  chunks.push(Buffer.from(xref.join(''), 'ascii'));
  return Buffer.concat(chunks);
}

const phrases = {
  es: 'LECTURA EN ESPANOL',
  en: 'READING IN ENGLISH',
  pt: 'LEITURA CLARA E SEGURA',
};
const longSubjects = ['historia', 'ciencia', 'musica', 'memoria', 'lenguaje', 'ciudad', 'naturaleza', 'educacion', 'tecnologia', 'cultura'];
const longActions = ['compara fuentes', 'ordena argumentos', 'describe cambios', 'explica causas', 'revisa pruebas', 'conecta ideas', 'plantea preguntas', 'resume hallazgos', 'analiza ejemplos', 'contrasta perspectivas'];
const longOutcomes = ['una conclusion clara', 'un problema concreto', 'una decision razonada', 'un proceso gradual', 'una experiencia comun', 'una relacion importante', 'una propuesta verificable', 'un aprendizaje util', 'una consecuencia visible', 'una interpretacion abierta'];
const longBody = (index) => {
  const subject = longSubjects[index % longSubjects.length];
  const action = longActions[Math.floor(index / longSubjects.length) % longActions.length];
  const outcome = longOutcomes[Math.floor(index / 100) % longOutcomes.length];
  return `Este parrafo sobre ${subject} ${action} y desarrolla ${outcome} para mantener una lectura continua.`;
};
const definitions = [];
for (const language of ['es', 'en', 'pt']) {
  definitions.push({ id: `${language}-single-digital`, language, layout: 'single_column', content: 'digital', mode: 'digital' });
  definitions.push({ id: `${language}-multi-digital`, language, layout: 'multi_column', content: 'digital', mode: 'multicolumn' });
  definitions.push({ id: `${language}-single-scanned`, language, layout: 'single_column', content: 'scanned', mode: 'scanned' });
  definitions.push({ id: `${language}-mixed`, language, layout: 'multi_column', content: 'mixed', mode: 'mixed' });
}
definitions.push({ id: 'long-1000-pages', language: 'es', layout: 'single_column', content: 'digital', mode: 'digital', role: 'long_form', pageCount: 1000 });
definitions.push({ id: 'adversarial-rotated', language: 'en', layout: 'single_column', content: 'digital', mode: 'digital', role: 'adversarial', rotate: true });

const entries = definitions.map((definition) => {
  const pageCount = definition.pageCount ?? 1;
  const phrase = definition.id === 'long-1000-pages' ? 'LECTURA PAGINA' : phrases[definition.language];
  const pages = Array.from(
    { length: pageCount },
    (_, index) => definition.id === 'long-1000-pages'
      ? `${phrase} ${index + 1}\n${longBody(index)}`
      : `${phrase} ${index + 1}`,
  );
  const pdf = buildPdf({ pages, mode: definition.mode, rotate: definition.rotate });
  const pdfName = `${definition.id}.pdf`;
  writeFileSync(join(documentsRoot, pdfName), pdf);

  const evaluatedPages = [0];
  const truthBlocks = (pageIndex) => {
    const texts = definition.id === 'long-1000-pages'
      ? pages[pageIndex].split('\n')
      : definition.mode === 'multicolumn'
      ? [pages[pageIndex], `${pages[pageIndex]} COLUMN TWO`]
      : definition.mode === 'mixed'
        ? [pages[pageIndex], pages[pageIndex]]
        : [pages[pageIndex]];
    return texts.map((text, order) => ({
      block_id: `${definition.id}-block-${order}`,
      order,
      text,
      region: order === 0
        ? [0.1, 0.08, definition.mode === 'multicolumn' ? 0.38 : 0.8, 0.12]
        : definition.id === 'long-1000-pages'
          ? [0.1, 0.13, 0.8, 0.12]
        : definition.mode === 'mixed'
          ? [0.1, 0.25, 0.8, 0.12]
          : [0.51, 0.08, 0.38, 0.12],
      paragraphs: [{
        paragraph_id: `${definition.id}-paragraph-${order}`,
        sentences: [{ sentence_id: `${definition.id}-sentence-${order}`, text }],
      }],
      degradation: definition.role === 'adversarial' ? 'rotated_page' : null,
    }));
  };
  const truth = {
    schema_version: 1,
    document_id: definition.id,
    revision: 1,
    pages: evaluatedPages.map((pageIndex) => ({
      page_index: pageIndex,
      blocks: truthBlocks(pageIndex),
    })),
    unsupported: definition.role === 'adversarial' ? ['embedded_actions_not_executed'] : [],
  };
  const truthName = `${definition.id}.json`;
  writeFileSync(join(expectedRoot, truthName), `${JSON.stringify(truth, null, 2)}\n`);

  return {
    id: definition.id,
    role: definition.role ?? 'matrix',
    file: `documents/${pdfName}`,
    sha256: createHash('sha256').update(pdf).digest('hex'),
    byte_size: pdf.length,
    provenance: { source: 'scripts/generate-corpus-fixtures.mjs', permission: 'owned', evidence: 'deterministic-generator-v1' },
    classification: { layout: definition.layout, content: definition.content },
    language: definition.language,
    required: true,
    distributable: true,
    page_count: pageCount,
    pages_evaluated: evaluatedPages,
    ground_truth: `expected/${truthName}`,
  };
});

writeFileSync(join(corpusRoot, 'manifest.json'), `${JSON.stringify({ schema_version: 1, corpus_id: 'lf-corpus-v1', entries }, null, 2)}\n`);
