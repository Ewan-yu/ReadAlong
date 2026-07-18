import { useQuery } from "@tanstack/react-query";
import { useParams } from "@tanstack/react-router";
import { ArrowLeft, CheckCircle2, Construction } from "lucide-react";

import { bookStateQuery } from "../../api/queries";
import type { WorkflowStep } from "../../app/step-gates";
import styles from "./StepPlaceholder.module.css";

type Props = { step: WorkflowStep; title: string; nextMilestone: string };

export function StepPlaceholder({ step, title, nextMilestone }: Props) {
  const { bookId } = useParams({ strict: false }) as { bookId: string };
  const { data } = useQuery(bookStateQuery(bookId));
  const pagesDone = data?.steps.pages?.status === "done";

  return (
    <section className={styles.page}>
      <header className={styles.header}>
        <p>工作区 / {data?.book_id ?? bookId}</p>
        <h1>{title}</h1>
      </header>
      <div className={styles.workspace}>
        <span className={styles.index}>0{step}</span>
        <Construction aria-hidden="true" />
        <div>
          <h2>{pagesDone && step === 2 ? "页面分析已完成" : "工作区已解锁"}</h2>
          <p>{nextMilestone}</p>
          <p className={styles.status}>
            <CheckCircle2 aria-hidden="true" />
            Pipeline 状态与步骤门禁已连接到当前工作区
          </p>
        </div>
      </div>
      <a className={styles.back} href="/books/new"><ArrowLeft />新建另一本绘本</a>
    </section>
  );
}
