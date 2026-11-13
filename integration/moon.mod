name = "moonbitstack/moonstate-ecosystem"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/moonbitstack/moonstate"

license = "Apache-2.0"

keywords = [
  "moonstate",
  "checkpoint",
  "sqlite",
  "postgres",
  "mysql",
  "integration",
  "moonbit",
]

description = "The same checkpoint scenarios run against the in-memory saver and the three SQL backends, to show they answer alike."

source = "src"

import {
  "moonbitlang/async@0.22.5",
  "moonbitstack/moonstate@0.1.0",
  "moonbitstack/moondb@0.3.0",
  "moonbitstack/moonsqlite@0.4.0",
  "moonbitstack/moonpostgres@0.7.0",
  "moonbitstack/moonmysql@0.8.0",
}
