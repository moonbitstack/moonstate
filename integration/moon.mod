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
  "moonbitstack/moonstate@0.2.1",
  "moonbitstack/moondb@0.3.1",
  "moonbitstack/moonsqlite@0.4.1",
  "moonbitstack/moonpostgres@0.7.1",
  "moonbitstack/moonmysql@0.8.1",
}
