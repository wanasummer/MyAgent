import * as fs from 'fs';
import * as path from 'path';

export interface FileInfo {
  name: string;
  path: string;
  size: number;
  isDirectory: boolean;
  extension?: string;
  modifiedTime: Date;
}

export interface SearchResult {
  file: string;
  line: number;
  content: string;
}

export class FileUtils {
  /**
   * 列出目录内容
   */
  static listDirectory(dirPath: string, recursive: boolean = false): FileInfo[] {
    const absolutePath = path.resolve(dirPath);
    const files: FileInfo[] = [];

    try {
      const items = fs.readdirSync(absolutePath);

      for (const item of items) {
        const itemPath = path.join(absolutePath, item);
        try {
          const stats = fs.statSync(itemPath);
          const fileInfo: FileInfo = {
            name: item,
            path: itemPath,
            size: stats.size,
            isDirectory: stats.isDirectory(),
            extension: stats.isFile() ? path.extname(item) : undefined,
            modifiedTime: stats.mtime
          };
          files.push(fileInfo);

          // 递归遍历子目录
          if (recursive && stats.isDirectory()) {
            const subFiles = this.listDirectory(itemPath, true);
            files.push(...subFiles);
          }
        } catch (error) {
          console.warn(`无法访问文件 ${itemPath}: ${error}`);
        }
      }
    } catch (error) {
      console.error(`无法读取目录 ${absolutePath}: ${error}`);
      throw error;
    }

    return files;
  }

  /**
   * 在文件中搜索文本
   */
  static searchInFile(filePath: string, searchText: string): SearchResult[] {
    const results: SearchResult[] = [];
    const absolutePath = path.resolve(filePath);

    try {
      const content = fs.readFileSync(absolutePath, 'utf-8');
      const lines = content.split('\n');

      for (let i = 0; i < lines.length; i++) {
        if (lines[i].includes(searchText)) {
          results.push({
            file: absolutePath,
            line: i + 1,
            content: lines[i].trim()
          });
        }
      }
    } catch (error) {
      console.error(`无法读取文件 ${absolutePath}: ${error}`);
    }

    return results;
  }

  /**
   * 递归在目录中搜索文件
   */
  static searchFiles(dirPath: string, pattern: RegExp | string, recursive: boolean = true): string[] {
    const absolutePath = path.resolve(dirPath);
    const files: string[] = [];

    try {
      const items = fs.readdirSync(absolutePath);

      for (const item of items) {
        const itemPath = path.join(absolutePath, item);
        try {
          const stats = fs.statSync(itemPath);

          // 检查是否匹配模式
          const isMatch = typeof pattern === 'string'
            ? item.includes(pattern)
            : pattern.test(item);

          if (isMatch) {
            files.push(itemPath);
          }

          // 递归遍历子目录
          if (recursive && stats.isDirectory()) {
            const subFiles = this.searchFiles(itemPath, pattern, true);
            files.push(...subFiles);
          }
        } catch (error) {
          console.warn(`无法访问文件 ${itemPath}: ${error}`);
        }
      }
    } catch (error) {
      console.error(`无法读取目录 ${absolutePath}: ${error}`);
    }

    return files;
  }

  /**
   * 复制文件
   */
  static copyFile(source: string, destination: string): boolean {
    try {
      const sourcePath = path.resolve(source);
      const destPath = path.resolve(destination);

      // 确保目标目录存在
      const destDir = path.dirname(destPath);
      if (!fs.existsSync(destDir)) {
        fs.mkdirSync(destDir, { recursive: true });
      }

      fs.copyFileSync(sourcePath, destPath);
      console.log(`已复制文件: ${sourcePath} -> ${destPath}`);
      return true;
    } catch (error) {
      console.error(`复制文件失败: ${error}`);
      return false;
    }
  }

  /**
   * 删除文件或目录
   */
  static deletePath(target: string): boolean {
    try {
      const targetPath = path.resolve(target);

      if (!fs.existsSync(targetPath)) {
        console.warn(`路径不存在: ${targetPath}`);
        return false;
      }

      const stats = fs.statSync(targetPath);

      if (stats.isDirectory()) {
        fs.rmSync(targetPath, { recursive: true, force: true });
        console.log(`已删除目录: ${targetPath}`);
      } else {
        fs.unlinkSync(targetPath);
        console.log(`已删除文件: ${targetPath}`);
      }

      return true;
    } catch (error) {
      console.error(`删除失败: ${error}`);
      return false;
    }
  }

  /**
   * 创建新文件
   */
  static createFile(filePath: string, content: string = ''): boolean {
    try {
      const absolutePath = path.resolve(filePath);

      // 确保目录存在
      const dir = path.dirname(absolutePath);
      if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
      }

      fs.writeFileSync(absolutePath, content, 'utf-8');
      console.log(`已创建文件: ${absolutePath}`);
      return true;
    } catch (error) {
      console.error(`创建文件失败: ${error}`);
      return false;
    }
  }

  /**
   * 追加内容到文件
   */
  static appendToFile(filePath: string, content: string): boolean {
    try {
      const absolutePath = path.resolve(filePath);

      if (!fs.existsSync(absolutePath)) {
        return this.createFile(absolutePath, content);
      }

      fs.appendFileSync(absolutePath, content + '\n', 'utf-8');
      console.log(`已追加内容到文件: ${absolutePath}`);
      return true;
    } catch (error) {
      console.error(`追加文件失败: ${error}`);
      return false;
    }
  }

  /**
   * 获取文件统计信息
   */
  static getFileStats(filePath: string): fs.Stats | null {
    try {
      const absolutePath = path.resolve(filePath);
      return fs.statSync(absolutePath);
    } catch (error) {
      console.error(`获取文件统计信息失败: ${error}`);
      return null;
    }
  }

  /**
   * 格式化文件大小
   */
  static formatSize(bytes: number): string {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let size = bytes;
    let unitIndex = 0;

    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }

    return `${size.toFixed(2)} ${units[unitIndex]}`;
  }
}