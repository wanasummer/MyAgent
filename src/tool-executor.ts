/**
 * 工具执行器 — 将 LLM 工具调用映射到真实的本地函数。
 * 不依赖任何 AI 逻辑，纯粹的函数调度层。
 */

import { FileUtils } from "./utils/file-utils";
import * as fs from "fs";
import * as path from "path";
import * as os from "os";

/**
 * 归一化路径：展开 ~ 波浪号，并解析为绝对路径。
 * 解决 Node.js 不识别 ~ 的问题。
 */
function resolvePath(p: string): string {
  if (p.startsWith("~")) {
    p = path.join(os.homedir(), p.slice(1));
  }
  return path.resolve(p);
}

export function executeTool(
  name: string,
  args: Record<string, unknown>
): unknown {
  switch (name) {
    // ── 目录操作 ──────────────────────────────
    case "list_directory":
      return FileUtils.listDirectory(
        resolvePath((args.dirPath as string) || "."),
        (args.recursive as boolean) || false
      );

    // ── 文件读写 ──────────────────────────────
    case "read_file": {
      const fp = resolvePath(args.filePath as string);
      if (!fs.existsSync(fp)) {
        return { error: `文件不存在: ${fp}` };
      }
      return fs.readFileSync(fp, "utf-8");
    }

    case "write_file":
      return {
        success: FileUtils.createFile(
          resolvePath(args.filePath as string),
          (args.content as string) || ""
        ),
      };

    case "append_file":
      return {
        success: FileUtils.appendToFile(
          resolvePath(args.filePath as string),
          (args.content as string) || ""
        ),
      };

    // ── 搜索 ──────────────────────────────────
    case "search_text":
      return FileUtils.searchInFile(
        resolvePath(args.filePath as string),
        args.searchText as string
      );

    case "search_files":
      return FileUtils.searchFiles(
        resolvePath((args.dirPath as string) || "."),
        args.pattern as string,
        args.recursive !== false // 默认 true
      );

    // ── 文件信息 ──────────────────────────────
    case "get_file_info": {
      const fp = resolvePath(args.filePath as string);
      const stats = FileUtils.getFileStats(fp);
      if (!stats) {
        return { error: `无法获取文件信息: ${fp}` };
      }
      return {
        size: stats.size,
        sizeFormatted: FileUtils.formatSize(stats.size),
        modifiedTime: stats.mtime,
        isDirectory: stats.isDirectory(),
        isFile: stats.isFile(),
      };
    }

    // ── 文件操作 ──────────────────────────────
    case "copy_file":
      return {
        success: FileUtils.copyFile(
          resolvePath(args.source as string),
          resolvePath(args.destination as string)
        ),
      };

    case "move_path": {
      const src = resolvePath(args.source as string);
      const dest = resolvePath(args.destination as string);

      if (!fs.existsSync(src)) {
        return { error: `源路径不存在: ${src}` };
      }

      // 确保目标父目录存在
      const destDir = path.dirname(dest);
      if (!fs.existsSync(destDir)) {
        fs.mkdirSync(destDir, { recursive: true });
      }

      try {
        fs.renameSync(src, dest);
        return { success: true, from: src, to: dest };
      } catch (err: any) {
        return { error: `移动失败: ${err.message}` };
      }
    }

    case "delete_path":
      return {
        success: FileUtils.deletePath(resolvePath(args.target as string)),
      };

    default:
      return { error: `未知工具: ${name}` };
  }
}
