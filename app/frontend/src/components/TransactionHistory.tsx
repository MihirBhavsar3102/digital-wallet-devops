import React from "react";
import DataTable, { TableColumn } from "react-data-table-component";
import { useAuth } from "../context/AuthContext";

interface Transaction {
  id: number;
  fromAccountId: number;
  toAccountId: number;
  type: "TRANSFER" | "DEPOSIT" | "WITHDRAWAL";
  amount: number;
  status: "SUCCESS" | "FAILURE";
  createdAt: string;
}

const TransactionHistory: React.FC = () => {
  const { transactions } = useAuth();

  const columns: TableColumn<Transaction>[] = [
    {
      name: "Date",
      selector: (row) => new Date(row.createdAt).toLocaleString(),
      sortable: true,
    },
    {
      name: "Type",
      selector: (row) => row.type,
      sortable: true,
    },
    {
      name: "Amount",
      selector: (row) => `$${row.amount.toFixed(2)}`,
      sortable: true,
    },
    {
      name: "Status",
      selector: (row) => row.status,
      sortable: true,
      cell: (row) => (
        <span
          className={
            row.status === "SUCCESS" ? "text-green-500" : "text-red-500"
          }
        >
          {row.status}
        </span>
      ),
    },
    {
      name: "Recipient",
      selector: (row) =>
        row.type === "TRANSFER" ? `Account #${row.toAccountId}` : "Self",
      sortable: true,
    },
  ];

  return (
    <div className="mt-8">
      <h2 className="text-xl font-semibold mb-4 text-gray-700">
        Transaction History
      </h2>
      <DataTable
        columns={columns}
        data={transactions}
        pagination
        highlightOnHover
        responsive
        className="rounded-lg shadow-md"
      />
    </div>
  );
};

export default TransactionHistory;
