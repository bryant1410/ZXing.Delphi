{
  * Copyright 2008 ZXing authors
  *
  * Licensed under the Apache License, Version 2.0 (the "License");
  * you may not use this file except in compliance with the License.
  * You may obtain a copy of the License at
  *
  *      http://www.apache.org/licenses/LICENSE-2.0
  *
  * Unless required by applicable law or agreed to in writing, software
  * distributed under the License is distributed on an "AS IS" BASIS,
  * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  * See the License for the specific language governing permissions and
  * limitations under the License.

  * Original Author: Sean Owen
  * Delphi Implementation by K. Gossens
}

unit ZXing.Datamatrix.Internal.Detector;

interface

uses
  System.SysUtils,
  System.Math,
  System.Generics.Defaults,
  System.Generics.Collections,
  ZXing.Common.BitMatrix,
  DefaultGridSampler,
  ZXing.Common.DetectorResult,
  ZXing.ResultPoint,
  ZXing.Common.GridSampler,
  ZXing.Common.Detector.MathUtils,
  ZXing.Common.Detector.WhiteRectangleDetector;

type
  /// <summary>
  /// <p>Encapsulates logic that can detect a Data Matrix Code in an image, even if the Data Matrix Code
  /// is rotated or skewed, or partially obscured.</p>
  /// </summary>
  TDataMatrixDetector = class(TObject)
  private
  class var
    Fimage: TBitMatrix;
    FrectangleDetector: TWhiteRectangleDetector;

  type
    /// <summary>
    /// Simply encapsulates two points and a number of transitions between them.
    /// </summary>
    TResultPointsAndTransitions = class sealed
    public
      From: TResultPoint;
      To_: TResultPoint;
      Transitions: Integer;

      constructor Create(From: TResultPoint; To_: TResultPoint;
        Transitions: Integer);
      destructor Destroy; override;
      function ToString: String; override;
    end;

    /// <summary>
    /// Orders ResultPointsAndTransitions by number of transitions, ascending.
    /// </summary>
    TResultPointsAndTransitionsComparator = class sealed
      (TComparer<TResultPointsAndTransitions>)
    public
      function Compare(const o1, o2: TResultPointsAndTransitions)
        : Integer; override;
    end;

  var
    FtransCompare: TResultPointsAndTransitionsComparator;
  public
    constructor Create(const image: TBitMatrix);
    destructor Destroy; override;
    function detect: TDetectorResult;
    function transitionsBetween(Afrom, Ato: TResultPoint)
      : TResultPointsAndTransitions;
    function distance(a: TResultPoint; b: TResultPoint): Integer;
    procedure increment(table: TDictionary<TResultPoint, Integer>;
      key: TResultPoint);
    function sampleGrid(image: TBitMatrix; topLeft, bottomLeft, bottomRight,
      topRight: TResultPoint; dimensionX, dimensionY: Integer): TBitMatrix;
    function isValid(p: TResultPoint): Boolean;
    function correctTopRight(bottomLeft, bottomRight, topLeft,
      topRight: TResultPoint; dimension: Integer): TResultPoint;
    function correctTopRightRectangular(bottomLeft, bottomRight, topLeft,
      topRight: TResultPoint; dimensionTop, dimensionRight: Integer)
      : TResultPoint;
  end;

implementation

{ TDataMatrixDetector }

/// <summary>
/// Initializes a new instance of the <see cref="Detector"/> class.
/// </summary>
/// <param name="image">The image.</param>
constructor TDataMatrixDetector.Create(const image: TBitMatrix);
begin
  Self.Fimage := image;
  Self.FrectangleDetector := TWhiteRectangleDetector.New(image);
  Self.FtransCompare := TResultPointsAndTransitionsComparator.Create;
end;

destructor TDataMatrixDetector.Destroy;
begin
  if (FrectangleDetector <> nil) then
    FrectangleDetector.Free;

  FtransCompare.Free;
  inherited;
end;

/// <summary>
/// <p>Detects a Data Matrix Code in an image.</p>
/// </summary>
/// <returns><see cref="DetectorResult" />encapsulating results of detecting a Data Matrix Code or null</returns>
function TDataMatrixDetector.detect(): TDetectorResult;
var
  topRight: TResultPoint;
  bits: TBitMatrix;
  correctedTopRight: TResultPoint;
  entry: TPair<TResultPoint, Integer>; // TKeyValuePair
  cornerPoints: TArray<TResultPoint>;
  pointA, pointB, pointC, pointD: TResultPoint;
  Transitions: TObjectList<TResultPointsAndTransitions>;
  lSideOne, lSideTwo, transBetween, transA, transB: TResultPointsAndTransitions;
  pointCount: TDictionary<TResultPoint, Integer>;

  maybeTopLeft, bottomLeft, bottomRight, topLeft, maybeBottomRight,
    point: TResultPoint;

  corners: TArray<TResultPoint>;

  i, dimensionTop, dimensionRight, dimension, dimensionCorrected: Integer;
begin
  Result := nil;
  pointCount := nil;

  if (FrectangleDetector = nil) then
    // can be null, if the image is to small
    exit;

  cornerPoints := FrectangleDetector.detect();
  if (cornerPoints = nil) then
    exit;

  pointA := cornerPoints[0];
  pointB := cornerPoints[1];
  pointC := cornerPoints[2];
  pointD := cornerPoints[3];

  // Point A and D are across the diagonal from one another,
  // as are B and C. Figure out which are the solid black lines
  // by counting transitions
  Transitions := TObjectList<TResultPointsAndTransitions>.Create;
  pointCount := TDictionary<TResultPoint, Integer>.Create();
  try
    Transitions.Add(transitionsBetween(pointA, pointB));
    Transitions.Add(transitionsBetween(pointA, pointC));
    Transitions.Add(transitionsBetween(pointB, pointD));
    Transitions.Add(transitionsBetween(pointC, pointD));
    Transitions.Sort(FtransCompare);

    // Sort by number of transitions. First two will be the two solid sides; last two
    // will be the two alternating black/white sides
    lSideOne := Transitions[0];
    lSideTwo := Transitions[1];

    // Figure out which point is their intersection by tallying up the number of times we see the
    // endpoints in the four endpoints. One will show up twice.

    increment(pointCount, lSideOne.From);
    increment(pointCount, lSideOne.To_);
    increment(pointCount, lSideTwo.From);
    increment(pointCount, lSideTwo.To_);

    maybeTopLeft := nil;
    bottomLeft := nil;
    maybeBottomRight := nil;

    for entry in pointCount do
    begin
      point := entry.key;
      if (entry.Value = 2) then
        bottomLeft := point
        // this is definitely the bottom left, then -- end of two L sides
      else
      begin
        // Otherwise it's either top left or bottom right -- just assign the two arbitrarily now
        if (maybeTopLeft = nil) then
          maybeTopLeft := point
        else
          maybeBottomRight := point;
      end;
    end;

    if ((maybeTopLeft = nil) or (bottomLeft = nil) or (maybeBottomRight = nil))
    then
      exit;

    // Bottom left is correct but top left and bottom right might be switched
    corners := TArray<TResultPoint>.Create(maybeTopLeft, bottomLeft,
      maybeBottomRight);
    // Use the dot product trick to sort them out
    TResultPoint.orderBestPatterns(corners);

    // Now we know which is which:
    bottomRight := corners[0];
    bottomLeft := corners[1];
    topLeft := corners[2];

    // Which point didn't we find in relation to the "L" sides? that's the top right corner
    if (not pointCount.ContainsKey(pointA)) then
      topRight := pointA
    else if (not pointCount.ContainsKey(pointB)) then
      topRight := pointB
    else if (not pointCount.ContainsKey(pointC)) then
      topRight := pointC
    else
      topRight := pointD;

    // Next determine the dimension by tracing along the top or right side and counting black/white
    // transitions. Since we start inside a black module, we should see a number of transitions
    // equal to 1 less than the code dimension. Well, actually 2 less, because we are going to
    // end on a black module:

    // The top right point is actually the corner of a module, which is one of the two black modules
    // adjacent to the white module at the top right. Tracing to that corner from either the top left
    // or bottom right should work here.
    transBetween := transitionsBetween(topLeft, topRight);
    dimensionTop := transBetween.Transitions;
    transBetween.Free;

    transBetween := transitionsBetween(bottomRight, topRight);
    dimensionRight := transBetween.Transitions;
    transBetween.Free;

    if ((dimensionTop and $01) = 1) then
      // it can't be odd, so, round... up?
      Inc(dimensionTop);
    Inc(dimensionTop, 2);

    if ((dimensionRight and $01) = 1) then
      // it can't be odd, so, round... up?
      Inc(dimensionRight);
    Inc(dimensionRight, 2);

    // Rectangular symbols are 6x16, 6x28, 10x24, 10x32, 14x32, or 14x44. If one dimension is more
    // than twice the other, it's certainly rectangular, but to cut a bit more slack we accept it as
    // rectangular if the bigger side is at least 7/4 times the other:
    if (((4 * dimensionTop) >= (7 * dimensionRight)) or
      ((4 * dimensionRight) >= (7 * dimensionTop))) then
    begin
      // The matrix is rectangular
      correctedTopRight := correctTopRightRectangular(bottomLeft, bottomRight,
        topLeft, topRight, dimensionTop, dimensionRight);
      if (correctedTopRight = nil) then
        correctedTopRight := topRight;

      transBetween := transitionsBetween(topLeft, correctedTopRight);
      dimensionTop := transBetween.Transitions;
      transBetween.Free;

      transBetween := transitionsBetween(bottomRight, correctedTopRight);
      dimensionRight := transBetween.Transitions;
      transBetween.Free;

      if ((dimensionTop and $01) = 1) then
        // it can't be odd, so, round... up?
        Inc(dimensionTop);

      if ((dimensionRight and $01) = 1) then
        // it can't be odd, so, round... up?
        Inc(dimensionRight);

      bits := sampleGrid(Fimage, topLeft, bottomLeft, bottomRight,
        correctedTopRight, dimensionTop, dimensionRight)
    end
    else
    begin
      // The matrix is square
      dimension := System.Math.Min(dimensionRight, dimensionTop);
      // correct top right point to match the white module
      correctedTopRight := correctTopRight(bottomLeft, bottomRight, topLeft,
        topRight, dimension);
      if (correctedTopRight = nil) then
        correctedTopRight := topRight;

      // Redetermine the dimension using the corrected top right point
      transA := transitionsBetween(topLeft, correctedTopRight);
      transB := transitionsBetween(bottomRight, correctedTopRight);
      dimensionCorrected :=
        (System.Math.Max(transA.Transitions, transB.Transitions) + 1);

      transA.Free;
      transB.Free;



      if ((dimensionCorrected and $01) = 1) then
        Inc(dimensionCorrected);

      bits := sampleGrid(Fimage, topLeft, bottomLeft, bottomRight,
        correctedTopRight, dimensionCorrected, dimensionCorrected);
    end;

    if (bits = nil) then
      exit;

    Result := TDetectorResult.Create(bits, TArray<TResultPoint>.Create(topLeft,
      bottomLeft, bottomRight, correctedTopRight));
  finally
    { for i := 0 to Pred(transitions.Count) do
      begin
      if (transitions.Items[i] <> nil) then
      begin
      if (transitions.Items[i].From <> nil)
      then
      transitions.Items[i].From.Free;
      if (transitions.Items[i].To_ <> nil)
      then
      transitions.Items[i].To_.Free;
      transitions.Items[i] := nil;
      end;
      end; }

//    for entry in pointCount do
//    begin
//      entry.Key.Free;
//    end;

    pointCount.Free;

    Transitions.Free;
  end;
end;

/// <summary>
/// Calculates the position of the white top right module using the output of the rectangle detector
/// for a rectangular matrix
/// </summary>
function TDataMatrixDetector.correctTopRightRectangular(bottomLeft, bottomRight,
  topLeft, topRight: TResultPoint; dimensionTop, dimensionRight: Integer)
  : TResultPoint;
var
  corr, norm, cos, sin: Single;
  c1, c2: TResultPoint;
  l1, l2: Integer;
begin
  corr := (distance(bottomLeft, bottomRight) / dimensionTop);
  norm := distance(topLeft, topRight);
  if (norm = 0) then
  begin
    Result := nil;
    exit
  end;
  cos := ((topRight.X - topLeft.X) / norm);
  sin := ((topRight.Y - topLeft.Y) / norm);

  c1 := TResultPoint.Create((topRight.X + (corr * cos)),
    (topRight.Y + (corr * sin)));

  corr := (distance(bottomLeft, topLeft) / dimensionRight);
  norm := distance(bottomRight, topRight);
  if (norm = 0) then
  begin
    Result := nil;
    exit;
  end;
  cos := ((topRight.X - bottomRight.X) / norm);
  sin := ((topRight.Y - bottomRight.Y) / norm);

  c2 := TResultPoint.Create((topRight.X + (corr * cos)),
    (topRight.Y + (corr * sin)));
  if (not isValid(c1)) then
  begin
    if (isValid(c2)) then
    begin
      Result := c2;
      c1.Free;
      exit;
    end;

    Result := nil;
    c1.Free;
    c2.Free;
    exit;
  end;
  if (not isValid(c2)) then
  begin
    Result := c1;
    c2.Free;
    exit;
  end;

  l1 := (Abs((dimensionTop - transitionsBetween(topLeft, c1).Transitions)) +
    Abs((dimensionRight - transitionsBetween(bottomRight, c1).Transitions)));
  l2 := (Abs((dimensionTop - transitionsBetween(topLeft, c2).Transitions)) +
    Abs((dimensionRight - transitionsBetween(bottomRight, c2).Transitions)));

  if (l1 <= l2) then
  begin
    Result := c1;
    c2.Free;
  end
  else
  begin
    Result := c2;
    c1.Free;
  end;
end;

/// <summary>
/// Calculates the position of the white top right module using the output of the rectangle detector
/// for a square matrix
/// </summary>
function TDataMatrixDetector.correctTopRight(bottomLeft, bottomRight, topLeft,
  topRight: TResultPoint; dimension: Integer): TResultPoint;
var
  corr, cos, sin: Single;
  norm: Integer;
  c1, c2: TResultPoint;
  l1, l2: Integer;
  transA, transB: TResultPointsAndTransitions;
begin
  corr := (distance(bottomLeft, bottomRight) / dimension);
  norm := distance(topLeft, topRight);
  if (norm = 0) then
  begin
    Result := nil;
    exit;
  end;
  cos := ((topRight.X - topLeft.X) / norm);
  sin := ((topRight.Y - topLeft.Y) / norm);

  c1 := TResultPoint.Create((topRight.X + (corr * cos)),
    (topRight.Y + (corr * sin)));

  corr := (distance(bottomLeft, topLeft) / dimension);
  norm := distance(bottomRight, topRight);
  if (norm = 0) then
  begin
    Result := nil;
    exit;
  end;
  cos := ((topRight.X - bottomRight.X) / norm);
  sin := ((topRight.Y - bottomRight.Y) / norm);

  c2 := TResultPoint.Create((topRight.X + (corr * cos)),
    (topRight.Y + (corr * sin)));

  if (not isValid(c1)) then
  begin
    if (isValid(c2)) then
    begin
      Result := c2;
      c1.Free;
      exit;
    end;

    Result := nil;
    c1.Free;
    c2.Free;
    exit;
  end;

  if (not isValid(c2)) then
  begin
    Result := c1;
    c2.Free;
    exit;
  end;

  transA := transitionsBetween(topLeft, c1);
  transB := transitionsBetween(bottomRight, c1);
  l1 := (Abs(transA.Transitions - transB.Transitions));
  transA.Free;
  transB.Free;

  transA := transitionsBetween(topLeft, c2);
  transB := transitionsBetween(bottomRight, c2);
  l2 := (Abs(transA.Transitions - transB.Transitions));
  transA.Free;
  transB.Free;

  if (l1 <= l2) then
  begin
    Result := c1;
    c2.Free;
  end
  else
  begin
    Result := c2;
    c1.Free;
  end;

end;

function TDataMatrixDetector.isValid(p: TResultPoint): Boolean;
begin
  Result := ((((p.X >= 0) and (p.X < Fimage.Width)) and (p.Y > 0)) and
    (p.Y < Fimage.Height))
end;

// L2 distance
function TDataMatrixDetector.distance(a: TResultPoint; b: TResultPoint)
  : Integer;
begin
  Result := TMathUtils.round(TResultPoint.distance(a, b))
end;

/// <summary>
/// Increments the Integer associated with a key by one.
/// </summary>
procedure TDataMatrixDetector.increment
  (table: TDictionary<TResultPoint, Integer>; key: TResultPoint);
var
  Value: Integer;
begin
  if (table.ContainsKey(key)) then
  begin
    Value := table[key];
    table[key] := (Value + 1);
  end
  else
    table.Add(key, 1); // table[key] := 1;
end;

function TDataMatrixDetector.sampleGrid(image: TBitMatrix;
  topLeft, bottomLeft, bottomRight, topRight: TResultPoint;
  dimensionX, dimensionY: Integer): TBitMatrix;
begin
  // TGridSampler.instance
  Result := TDefaultGridSampler.sampleGrid(image, dimensionX, dimensionY, 0.5,
    0.5, (dimensionX - 0.5), 0.5, (dimensionX - 0.5), (dimensionY - 0.5), 0.5,
    (dimensionY - 0.5), topLeft.X, topLeft.Y, topRight.X, topRight.Y,
    bottomRight.X, bottomRight.Y, bottomLeft.X, bottomLeft.Y);
end;

/// <summary>
/// Counts the number of black/white transitions between two points, using something like Bresenham's algorithm.
/// </summary>
function TDataMatrixDetector.transitionsBetween(Afrom, Ato: TResultPoint)
  : TResultPointsAndTransitions;
var
  temp, fromX, fromY, toX, toY: Integer;
  steep: Boolean;
  dx, dy: Int64;
  xstep, ystep, Transitions: Integer;
  error: Int64;
  inBlack, isBlack: Boolean;
  X, Y: Integer;
begin
  // See QR Code Detector, sizeOfBlackWhiteBlackRun()
  fromX := Trunc(Afrom.X);
  fromY := Trunc(Afrom.Y);
  toX := Trunc(Ato.X);
  toY := Trunc(Ato.Y);
  steep := (Abs((toY - fromY)) > Abs((toX - fromX)));
  if (steep) then
  begin
    temp := fromX;
    fromX := fromY;
    fromY := temp;
    temp := toX;
    toX := toY;
    toY := temp;
  end;

  dx := Abs(toX - fromX);
  dy := Abs(toY - fromY);
  error := TMathUtils.Asr(-dx, 1);
  if (fromY < toY) then
    ystep := 1
  else
    ystep := -1;
  if (fromX < toX) then
    xstep := 1
  else
    xstep := -1;
  Transitions := 0;
  if steep then
    inBlack := Fimage[fromY, fromX]
  else
    inBlack := Fimage[fromX, fromY];

  X := fromX;
  Y := fromY;
  while ((X <> toX)) do
  begin
    if steep then
      isBlack := Fimage[Y, X]
    else
      isBlack := Fimage[X, Y];

    if (isBlack <> inBlack) then
    begin
      Inc(Transitions);
      inBlack := isBlack;
    end;
    Inc(error, dy);
    if (error > 0) then
    begin
      if (Y = toY) then
        break;
      Inc(Y, ystep);
      Dec(error, dx);
    end;
    Inc(X, xstep)
  end;

  Result := TResultPointsAndTransitions.Create(Afrom, Ato, Transitions);
end;

{ TResultPointsAndTransitions }

constructor TDataMatrixDetector.TResultPointsAndTransitions.Create
  (From: TResultPoint; To_: TResultPoint; Transitions: Integer);
begin
  Self.From := From;
  Self.To_ := To_;
  Self.Transitions := Transitions;
end;

destructor TDataMatrixDetector.TResultPointsAndTransitions.Destroy;
begin

  // if (Assigned(Self.From)) then
  // FreeAndNil(Self.From);
  //
  // if (Assigned(Self.To_)) then
  // FreeAndNil(Self.To_);

  inherited;
end;

function TDataMatrixDetector.TResultPointsAndTransitions.ToString: string;
begin
  Result := From.ToString + '/' + To_.ToString + '/' + IntToStr(Transitions);
end;

function TDataMatrixDetector.TResultPointsAndTransitionsComparator.Compare
  (const o1, o2: TResultPointsAndTransitions): Integer;
begin
  Result := (o1.Transitions - o2.Transitions);
end;

end.
