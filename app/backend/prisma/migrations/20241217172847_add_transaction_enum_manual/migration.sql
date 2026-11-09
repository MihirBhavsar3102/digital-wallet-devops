/*
  Warnings:

  - Made the column `type` on table `Transaction` required. This step will fail if there are existing NULL values in that column.

*/
-- AlterTable
ALTER TABLE "Transaction" ALTER COLUMN "type" SET NOT NULL;

-- CreateIndex
CREATE INDEX "Transaction_type_idx" ON "Transaction"("type");
