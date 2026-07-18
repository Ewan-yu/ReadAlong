import { useQuery } from "@tanstack/react-query";
import { Outlet, useNavigate, useRouterState } from "@tanstack/react-router";
import {
  AudioLines,
  BookOpen,
  Check,
  CircleHelp,
  FileUp,
  ImageDown,
  LockKeyhole,
  PackageCheck,
  Settings,
  TextCursorInput,
  UserRound,
} from "lucide-react";

import { bookStateQuery } from "../api/queries";
import { isStepComplete, isStepUnlocked, type WorkflowStep } from "./step-gates";
import styles from "./AppShell.module.css";

const steps = [
  { step: 1, label: "导入资源", hint: "PDF 与原音", icon: FileUp, match: "/books/new" },
  { step: 2, label: "页面处理", hint: "拆分与裁边", icon: ImageDown, match: "/pages" },
  { step: 3, label: "OCR 与句子", hint: "识别与校对", icon: TextCursorInput, match: "/proofread" },
  { step: 4, label: "语音生成", hint: "TTS 与时间戳", icon: AudioLines, match: "/audio" },
  { step: 5, label: "导出资源包", hint: "打包与校验", icon: PackageCheck, match: "/export" },
] as const;

function currentBookId(matches: ReturnType<typeof useRouterState>["matches"]): string | undefined {
  for (let index = matches.length - 1; index >= 0; index -= 1) {
    const value = (matches[index].params as { bookId?: string }).bookId;
    if (value) return value;
  }
  return undefined;
}

export function AppShell() {
  const route = useRouterState();
  const navigate = useNavigate();
  const bookId = currentBookId(route.matches);
  const stateQuery = useQuery({
    ...bookStateQuery(bookId ?? ""),
    enabled: Boolean(bookId),
  });
  const state = stateQuery.data;

  const goToStep = (step: WorkflowStep) => {
    if (step === 1) {
      void navigate({ to: "/books/new" });
    } else if (bookId && step === 2) {
      void navigate({ to: "/books/$bookId/pages", params: { bookId } });
    } else if (bookId && step === 3) {
      void navigate({ to: "/books/$bookId/proofread", params: { bookId } });
    } else if (bookId && step === 4) {
      void navigate({ to: "/books/$bookId/audio", params: { bookId } });
    } else if (bookId && step === 5) {
      void navigate({ to: "/books/$bookId/export", params: { bookId } });
    }
  };

  return (
    <div className={styles.shell}>
      <a className="skip-link" href="#main-content">跳到主要内容</a>
      <aside className={styles.sidebar} aria-label="加工流程">
        <div className={styles.brand}>
          <span className={styles.brandMark} aria-hidden="true"><BookOpen /></span>
          <span>
            <strong>ReadAlong</strong>
            <small>绘本加工台</small>
          </span>
        </div>

        <nav className={styles.workflow} aria-label="五步加工流程">
          {steps.map((item) => {
            const step = item.step as WorkflowStep;
            const active = route.location.pathname.includes(item.match);
            const unlocked = isStepUnlocked(state, step);
            const completed = isStepComplete(state, step);
            const Icon = item.icon;
            return (
              <button
                type="button"
                className={styles.step}
                data-active={active || undefined}
                data-complete={completed || undefined}
                disabled={!unlocked}
                onClick={() => goToStep(step)}
                key={step}
              >
                <span className={styles.stepRail} aria-hidden="true">
                  <span className={styles.stepNumber}>
                    {completed ? <Check /> : unlocked ? step : <LockKeyhole />}
                  </span>
                </span>
                <Icon className={styles.stepIcon} aria-hidden="true" />
                <span className={styles.stepCopy}>
                  <strong>{item.label}</strong>
                  <small>{item.hint}</small>
                </span>
              </button>
            );
          })}
        </nav>

        <div className={styles.sidebarFooter}>
          <button type="button" disabled><Settings />设置</button>
          <button type="button" disabled><CircleHelp />帮助与文档</button>
          <div className={styles.account}><UserRound /><span>家长账户</span></div>
        </div>
      </aside>
      <main id="main-content" className={styles.main}>
        <Outlet />
      </main>
    </div>
  );
}
