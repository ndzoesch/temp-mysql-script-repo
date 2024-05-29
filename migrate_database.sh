#!/bin/bash

# Destination and source database from command line arguments
dest_db=$1
src_db=$2

# Get the directory of this script
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# Define MySQL config paths
source_config="${DIR}/.my.cnf.source"
destination_config="${DIR}/.my.cnf.destination"

echo "Removing any existing files..."
# Remove existing files if they exist
rm -f changedLines.txt
rm -f tempStructure.sql
rm -f alter.sql

if [[ -z "$src_db" ]]; then
  if [[ ! -f structure.sql || ! -f data.sql ]]; then
    echo "No source database provided, and local SQL files not found."
    echo "Please specify a source database or ensure structure.sql and data.sql files are present."

    echo "To generate these files, you can use the mysqldump utility with a command similar to the following:"

    echo "mysqldump --single-transaction -h [hostname] -u [username] -p [database_name] --no-data > structure.sql"
    echo "To create the structure.sql file, use the command above, replacing [hostname] with your MySQL server's hostname, [username] with your MySQL username, and [database_name] with the name of your database."

    echo "mysqldump --single-transaction -h [hostname] -u [username] -p [database_name] --no-tablespaces --skip-triggers --complete-insert --no-create-info > data.sql"
    echo "To create the data.sql file, use the command above, replacing [hostname] with your MySQL server's hostname, [username] with your MySQL username, and [database_name] with the name of your database."

    exit 1
  fi
  echo "Using local SQL files..."
else
  echo "Exporting structure and data from source database..."
  # Get structure and data of source database
  mysqldump --defaults-extra-file="$source_config" --column-statistics=0 "$src_db" --no-data > structure.sql
  mysqldump --defaults-extra-file="$source_config" --column-statistics=0 "$src_db" --no-tablespaces --skip-triggers --complete-insert --no-create-info > data.sql
fi

echo "Identifying lines with GENERATED columns..."
# Identify lines with GENERATED columns
grep 'GENERATED ALWAYS AS' structure.sql > changedLines.txt

echo "Creating temporary structure SQL file..."
# Create temp structure SQL file
cp structure.sql tempStructure.sql
sed -i 's/GENERATED ALWAYS AS .* VIRTUAL/NOT NULL/' tempStructure.sql
sed -i 's/GENERATED ALWAYS AS .* STORED/NOT NULL/' tempStructure.sql

echo "Creating new database and importing temporary structure..."
# Create the new database and import the temp structure
mysql --defaults-extra-file="$destination_config" -e "DROP DATABASE IF EXISTS $dest_db; CREATE DATABASE $dest_db;"
mysql --defaults-extra-file="$destination_config" $dest_db < tempStructure.sql

echo "Importing data into the new database..."
# Import data into the new database
mysql --defaults-extra-file="$destination_config" $dest_db < data.sql

echo "Creating ALTER TABLE queries for GENERATED columns..."
# Create the ALTER TABLE queries for GENERATED columns
while read -r line; do
  # Get the name of the table by finding the CREATE TABLE line preceding the column line
  table=$(grep -B 1000 "$line" structure.sql | grep 'CREATE TABLE' | tail -1 | awk -F'`' '{print $2}')
  column=$(echo $line | awk -F'`' '{print $2}')
  columnType=$(grep -B 1000 "$line" structure.sql | grep "$column" | tail -1 | awk -F'`' '{print $3}'|awk '{print $1}')
  columnDetails=$(echo $line | awk '{print substr($0, index($0,$3))}' | sed 's/, *$//')

  # check how many times an altered line is found
  numOccurrences=$(grep -c "$line" structure.sql)

  if [[ -z "$table" || -z "$column" || -z "$columnDetails" ]]; then
    echo "Problematic line: $line"
  elif [[ $numOccurrences -gt 1 ]]; then
    echo "Duplicate line in structure.sql: $line"
  else
    echo "ALTER TABLE \`$table\` DROP COLUMN \`$column\`;" >> alter.sql
    echo "ALTER TABLE \`$table\` ADD COLUMN \`$column\` $columnType $columnDetails;" >> alter.sql
  fi
done < changedLines.txt

echo "Executing ALTER TABLE queries..."
# Execute the ALTER TABLE queries
mysql --defaults-extra-file="$destination_config" $dest_db < alter.sql

echo "Migration complete."