import { FileText, Music2, UploadCloud, X } from "lucide-react";
import { useDropzone } from "react-dropzone";

import styles from "./FileDropField.module.css";

type Props = {
  label: string;
  hint: string;
  accept: Record<string, string[]>;
  file?: File;
  optional?: boolean;
  onChange: (file: File | undefined) => void;
  error?: string;
};

export function FileDropField({ label, hint, accept, file, optional, onChange, error }: Props) {
  const { getRootProps, getInputProps, isDragActive, open } = useDropzone({
    accept,
    maxFiles: 1,
    multiple: false,
    noClick: true,
    onDropAccepted: ([next]) => onChange(next),
  });
  const FileIcon = optional ? Music2 : FileText;

  return (
    <div className={styles.field}>
      <div className={styles.labelRow}>
        <strong>{label}</strong>
        {optional && <span>可选</span>}
      </div>
      <div
        {...getRootProps()}
        className={styles.dropzone}
        data-active={isDragActive || undefined}
        data-filled={Boolean(file) || undefined}
        data-error={Boolean(error) || undefined}
      >
        <input {...getInputProps()} aria-label={label} />
        {file ? (
          <>
            <FileIcon aria-hidden="true" />
            <div className={styles.fileCopy}>
              <strong>{file.name}</strong>
              <small>{(file.size / 1024 / 1024).toFixed(1)} MB</small>
            </div>
            <button type="button" className={styles.remove} onClick={() => onChange(undefined)} aria-label={`移除${label}`}>
              <X />
            </button>
          </>
        ) : (
          <>
            <UploadCloud aria-hidden="true" />
            <div className={styles.emptyCopy}>
              <strong>{isDragActive ? "松开即可添加" : hint}</strong>
              <small>也可以从电脑中选择文件</small>
            </div>
            <button type="button" className={styles.choose} onClick={open}>选择文件</button>
          </>
        )}
      </div>
      {error && <p className={styles.error} role="alert">{error}</p>}
    </div>
  );
}
