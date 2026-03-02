# FlexBinFPC - Flexible Binary File Format Protocol
---
## Description
Binary file container used to store time measurement data with rich meta data support supported through a high level user defined interface via an xlsx file

- Structured format defined by data archival users provides
  - Clear documentation
  - Flexibility
  - Speed
  - Interoperability
- Open source to maximize Interoptability supporting multiple APIs
  - Julia
  - Python
  - Matlab
  - C/C++/C#

## DUFF - Defined User File Format
User defined file format used by FlexBinFPC to read/write file containers. The DUFF is captured in a XLSX file made up of a variable number of sheets that represent a hierarchy of tabular formats. The XLSX sheets represent tables of formats defined by the user know as [DUF Table](@ref)s.  There can be N tables defined by the user with the first table/sheet named **_`header0`_**.

### DUFF Hierarchy
The DUFF xlsx file and sheets are ordered and hierarchal.  FlexBinFPC starts with the first row of the default top level **_`header0`_** DUF table and iterates down each row until called to index into lower DUF table on the hierarchy.

### DUF Table
A DUF table is a composite data type or Defined User Format (DUF), where a developer/user creates a sheet/tab within the DUFF xlsx sreadsheet file made up of existing [DUF Type](@ref)s.

##### Each DUF table must contain columns:
```
varName     Type     Count     Description     Conditional     Argument     Default     Notes
```
##### DUF Table for **_`header0`_**
>| varName | Type | Count |Description|Conditional|Argument|Default| Notes|
>|:---     | :--  | --:   | :---      | :---      | :---   | :---  | :--- |
>|mdoHdr|mdoHdr|1|Mission Data Object header (Meta Data)|
>|mdoMeasHdr|mdoMeasHdr|1|Mission Data Object measurement header|

##### DUF Table for mdoMdr
>| varName | Type | Count |Description|Conditional|Argument|Default| Notes|
>|:---     | :--  | --:   | :---      | :---      | :---   | :---  | :--- |
>|numBytesHdr|UInt64|1|Number of bytes in header|
>|mdo_fileVer|StaticStr|24|mdo file version identification|||1.1|
>|mdo_Version|StaticStr|8|mdo Version|
>|missionName|StaticStr|32|Mission Name|

## DUF Column Variables

### DUF varName
The `varName` column defines the variable name used for each row in the DUF Table.  The `varName`s can be used as variables within the [DUF Count](@ref).

### DUF Type
1. Base/Primitive (Int64, UInt64, Float64, etc)
2. FlexBinFPC Composite - Predefined data types used by FlexBinFPC
3. User Defined - Composite of available data types

### DUF Count
The `Count` represents the number of data types for its respective variable row [DUF varName](@ref) within the [DUF Table](@ref) specified by the [DUF Type](@ref) column.  The `Count` can be a positive integer or a `varName` that represents a positive integer previously parsed within the DUF hierarchy.  FlexBinFPC also supports simple algebraic expressions and formulas in the `Count`.  The function `length` is also available to compute the number of existing [DUF varName](@ref) recently parsed by FlexBinFPC.

#### Valid DUF Count Expressions:
1. Positive integer used to represent the total size of Data Type
2. Previously parsed [DUF varName](@ref) that evaluated to a positive integer
3. Predefined function `length` to compute the number elements in a [DUF varName](@ref) vector

```
- Examples:
  - numRun
  - numRun * (numMeas + 1)
  - length(fieldNames)
```

### DUF Argument
The 'Argument' column allows the user to pass a varName from the current [DUF Table](@ref) to an underlying `DUF Table` specified by the current row [DUF varName](@ref).

There is a special case for an `Argument` that uses a predefined FlexBinFPC `varName` named `remBytesHdr`.  See example [Special Case DUF Example:](@ref)

#### Remaining Bytes in Header
For each [DUF Table](@ref) that starts with the `varName` `numBytesHdr`, FlexBinFPC computes the remaining bytes in that specific `DUF Table` and stores that number in the variable name `remBytesHdr`.  This variable name is available to be passed to the child DUF Table specified by the row's [DUF varName](@ref).

### DUF Conditional
The `Conditional` column allows the user to provide an Boolean expression for each DUF row, where an evaluation of false commands the FlexBinFPC parser to skip the current DUF row.
- `true`  - DUF row remains and is processed as normal (default - empty values resolve as true)
- `false` - Skip DUF row

There are special cases for `Conditional`s which include
- Zero Inhibit
- [DUF Table](@ref) Reference Switch

#### Zero Inhibit (zeroInhibit)
Zero Inhibit is a special use case of the `DUF Conditional`.  This case defines for the FlexBinFPC parser how to interpret a zero value of the [DUF Count](@ref).  The default case for a zero 'Count' assumes the FlexBinFPC parser will parse one instance of the specified [DUF varName](@ref).

- If DUF row Count is Zero and Zero Inhibit is true, skip the DUF row
```julia
`Count` == 0 && `Conditional` == "zeroInhibit = true" && return false
```
- If DUF row Count is Zero and Zero Inhibit is false set Row Count to 1
```julia
`Count` == 0 && `Conditional` == "zeroInhibit = false" && (`Count` = 1)
```
- If Row row Count is non Zero and Zero Inhibit is false, do nothing
```julia
`Count` >= 1 && `Conditional` == "zeroInhibit = false" && return true
```
##### Special Case DUF Example:
>| varName | Type | Count |Description|Conditional|Argument|Default| Notes|
>|:---     | :--  | --:   | :---      | :---      | :---   | :---  | :--- |
>|grpRunTotal|UInt64|1|Total number of runs in Group||||if total is greater than 1 the following 3 params are multiples of total run number|
>|grpName|StaticStr|32|Group Name|
>|grpInfoObj|grpInfo|grpRunTotal|Name, Run Number, and Run Name|zeroInhibit = false|||	zeroInhibit being false says Counts of 0 or 1 will expect 1 set of underlying data type (grpInfo)|
>|lvConst|Struct|1|LV Constants|
>|srcData|Struct|1|Source Data|
>|varList|genObj|1|Variable List|
>|ev|genObj|1|Flight Events|
>|evTimes|zipArray|1|Monte Carlo group event times (number events x number of runs)|grpRunTotal > 1|remBytesHdr||The zip array is the length of the remainder of bytes in the mdo header (numBytesHdr)|

#### DUF Table Reference Switch
`Conditional`s also allow the user to switch what DUF Table is being parsed at the current row index if the [DUF varName](@ref) evaluates to a valid number.

!!! warning "Warning Incomplete"
    This feature is still under development

---
---

## FlexBinFPC Unique Data Types
In addition to DUF Tables found within the DUFF xlsx spreadsheet there are unique data types used by FlexBinFPC

### StaticStr
This FlexBinFPC unique data type has a static size typically used to support static headers with in binary files. FlexBinFPC will read in N ASCII characters (UInt8) where N is specfied by the [DUF Count](@ref) and store in the result in the [DUF varName](@ref)

### BitArray
This FlexBinFPC unique data type allows users to define a list of discrete Boolean values. If FlexBinFPC comes across a [DUF Type](@ref) of `BitArray` it looks to the [DUF varName](@ref) to lookup a DUF table of that `varName`. FlexBinFPC then traverses into that DUF table where each row of the [DUF varName](@ref) is a discrete boolean name starting with the Least Significant Bit (LSB) to Most Significant Bit (MSB) as it iterates through the DUF table's rows. The size used in the FlexBinFPC file is quantized to 1 byte. Any bits or [DUF varName](@ref) rows that are unassigned, FlexBinFPC assumes zero or false bit values for the remainder of the bits in the byte.

---
---

## Loading FlexBinFPC Files
The FlexBinFPC load function opens and reads a FlexBinFPC binary file and uses the [DUFF - Defined User File Format](@ref) xlsx file to populate a dictionary with keys made from [DUF varName](@ref)s and values found at each subsequent read operation associated with each row in a [DUF Table](@ref).  A file read operation is only performed when the [DUF Type](@ref) of the current row index is a `Base/Primitive Type`; otherwise, the function continues to traverse the `DUFF` hierarchy through [DUF Table](@ref)s or [FlexBinFPC Unique Data Types](@ref).

```
julia> missionData = FlexBinFPC.load('inputBinaryFile.dat','DUFF.xlsx')
DUFF File:
[header0]
  └── mdoHdr
       ├── numBytesHdr
       ├── mdo_fileVer
       ├── mdo_Version
       ├── missionName
       ├── ...  
  └── mdoMeasHdr
       ├── numBytesMeasHdr
       ├── numRun
       ├── numGrp
       └── measGrp
```





