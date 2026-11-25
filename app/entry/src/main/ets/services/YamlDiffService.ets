export type DiffLineKind = 'same' | 'add' | 'del' | 'sep';

export interface DiffLine {
  kind: DiffLineKind;
  oldLineNo: number;
  newLineNo: number;
  text: string;
}

export interface DiffSummary {
  lines: DiffLine[];
  added: number;
  removed: number;
  changed: boolean;
}

export class YamlDiffService {
  static computeDiff(oldText: string, newText: string): DiffSummary {
    const oldLines: string[] = YamlDiffService.splitNormalizedLines(oldText);
    const newLines: string[] = YamlDiffService.splitNormalizedLines(newText);

    // Strip common prefix and suffix to keep DP matrix tiny even for large configs.
    let prefix: number = 0;
    const minLen: number = oldLines.length < newLines.length ? oldLines.length : newLines.length;
    while (prefix < minLen && oldLines[prefix] === newLines[prefix]) {
      prefix++;
    }

    let oldEnd: number = oldLines.length - 1;
    let newEnd: number = newLines.length - 1;
    while (oldEnd >= prefix && newEnd >= prefix && oldLines[oldEnd] === newLines[newEnd]) {
      oldEnd--;
      newEnd--;
    }

    const result: DiffLine[] = [];
    for (let i = 0; i < prefix; i++) {
      result.push({ kind: 'same', oldLineNo: i + 1, newLineNo: i + 1, text: oldLines[i] });
    }

    const m: number = oldEnd - prefix + 1;
    const n: number = newEnd - prefix + 1;
    let added: number = 0;
    let removed: number = 0;

    if (m > 0 && n > 0 && m * n <= 400000) {
      const cols: number = n + 1;
      const dp: Int32Array = new Int32Array((m + 1) * cols);
      for (let i = m - 1; i >= 0; i--) {
        for (let j = n - 1; j >= 0; j--) {
          if (oldLines[prefix + i] === newLines[prefix + j]) {
            dp[i * cols + j] = dp[(i + 1) * cols + (j + 1)] + 1;
          } else {
            const down: number = dp[(i + 1) * cols + j];
            const right: number = dp[i * cols + (j + 1)];
            dp[i * cols + j] = down >= right ? down : right;
          }
        }
      }

      let i: number = 0;
      let j: number = 0;
      while (i < m && j < n) {
        if (oldLines[prefix + i] === newLines[prefix + j]) {
          result.push({
            kind: 'same',
            oldLineNo: prefix + i + 1,
            newLineNo: prefix + j + 1,
            text: oldLines[prefix + i]
          });
          i++;
          j++;
        } else if (dp[(i + 1) * cols + j] >= dp[i * cols + (j + 1)]) {
          result.push({
            kind: 'del',
            oldLineNo: prefix + i + 1,
            newLineNo: 0,
            text: oldLines[prefix + i]
          });
          removed++;
          i++;
        } else {
          result.push({
            kind: 'add',
            oldLineNo: 0,
            newLineNo: prefix + j + 1,
            text: newLines[prefix + j]
          });
          added++;
          j++;
        }
      }
      while (i < m) {
        result.push({
          kind: 'del',
          oldLineNo: prefix + i + 1,
          newLineNo: 0,
          text: oldLines[prefix + i]
        });
        removed++;
        i++;
      }
      while (j < n) {
        result.push({
          kind: 'add',
          oldLineNo: 0,
          newLineNo: prefix + j + 1,
          text: newLines[prefix + j]
        });
        added++;
        j++;
      }
    } else {
      for (let i = 0; i < m; i++) {
        result.push({
          kind: 'del',
          oldLineNo: prefix + i + 1,
          newLineNo: 0,
          text: oldLines[prefix + i]
        });
        removed++;
      }
      for (let j = 0; j < n; j++) {
        result.push({
          kind: 'add',
          oldLineNo: 0,
          newLineNo: prefix + j + 1,
          text: newLines[prefix + j]
        });
        added++;
      }
    }

    const suffixCount: number = oldLines.length - 1 - oldEnd;
    for (let k = 0; k < suffixCount; k++) {
      const oi: number = oldEnd + 1 + k;
      const ni: number = newEnd + 1 + k;
      result.push({ kind: 'same', oldLineNo: oi + 1, newLineNo: ni + 1, text: oldLines[oi] });
    }

    return {
      lines: result,
      added: added,
      removed: removed,
      changed: added > 0 || removed > 0
    };
  }

  static filterChangedContext(lines: DiffLine[], radius: number = 3): DiffLine[] {
    const keep: boolean[] = [];
    for (let i = 0; i < lines.length; i++) {
      keep.push(false);
    }
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].kind === 'add' || lines[i].kind === 'del') {
        const start: number = i - radius > 0 ? i - radius : 0;
        const end: number = i + radius < lines.length - 1 ? i + radius : lines.length - 1;
        for (let k = start; k <= end; k++) {
          keep[k] = true;
        }
      }
    }

    const out: DiffLine[] = [];
    let skipping: boolean = false;
    for (let i = 0; i < lines.length; i++) {
      if (keep[i]) {
        if (skipping && out.length > 0) {
          out.push({ kind: 'sep', oldLineNo: 0, newLineNo: 0, text: '··· 省略未变更行 ···' });
        }
        skipping = false;
        out.push(lines[i]);
      } else {
        skipping = true;
      }
    }
    return out;
  }

  private static splitNormalizedLines(text: string): string[] {
    const normalized: string = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    if (normalized.length === 0) {
      return [];
    }
    return normalized.split('\n');
  }
}
