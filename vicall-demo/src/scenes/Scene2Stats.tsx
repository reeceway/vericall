import React from 'react';
import {Easing, interpolate, useCurrentFrame} from 'remotion';
import {SceneContainer} from '../components/SceneContainer';
import {colors, fonts} from '../theme';

const stats = [
	{
		value: '1,300%',
		eyebrow: 'Attack growth',
		label: 'surge in enterprise voice-based fraud attacks year over year',
		color: colors.danger,
	},
	{
		value: '3 Secs',
		eyebrow: 'Cloning threshold',
		label: "of audio can clone an employee's voice",
		color: colors.accent,
	},
	{
		value: '$40B',
		eyebrow: 'Projected losses',
		label: 'to AI-driven scams by 2027',
		color: colors.danger,
	},
];

export const Scene2Stats: React.FC<{durationInFrames?: number}> = ({durationInFrames}) => {
	const frame = useCurrentFrame();

	return (
		<SceneContainer durationInFrames={durationInFrames}>
			<div
				style={{
					flex: 1,
					display: 'flex',
					flexDirection: 'column',
					alignItems: 'center',
					justifyContent: 'center',
					gap: 28,
					padding: '0 96px',
				}}
			>
				<div
					style={{
						fontFamily: fonts.body,
						fontSize: 20,
						letterSpacing: 2.4,
						textTransform: 'uppercase',
						color: colors.inkSoft,
						textAlign: 'center',
						marginBottom: 4,
						maxWidth: 900,
					}}
				>
					The rising cost of unprotected communications
				</div>
				<div
					style={{
						display: 'grid',
						gridTemplateColumns: 'repeat(3, 340px)',
						alignItems: 'start',
						justifyItems: 'center',
						justifyContent: 'center',
						paddingTop: 18,
						borderTop: `1px solid ${colors.border}`,
					}}
				>
				{stats.map((stat, index) => {
					const start = 12 + index * 12;
					const progress = interpolate(frame, [start, start + 18], [0, 1], {
						extrapolateLeft: 'clamp',
						extrapolateRight: 'clamp',
						easing: Easing.out(Easing.cubic),
					});
					const numberProgress = interpolate(frame, [start + 4, start + 20], [0, 1], {
						extrapolateLeft: 'clamp',
						extrapolateRight: 'clamp',
						easing: Easing.out(Easing.cubic),
					});

					return (
						<div
							key={stat.value}
							style={{
								width: 340,
								padding: '22px 26px',
								borderLeft: index === 0 ? 'none' : `1px solid ${colors.border}`,
								display: 'flex',
								flexDirection: 'column',
								alignItems: 'center',
								transform: `translateY(${interpolate(progress, [0, 1], [30, 0])}px)`,
								opacity: progress,
							}}
						>
							<div
								style={{
									fontFamily: fonts.body,
									fontSize: 16,
									letterSpacing: 2.2,
									textTransform: 'uppercase',
									color: colors.inkSoft,
									fontWeight: 700,
									marginBottom: 20,
									textAlign: 'center',
								}}
							>
								{stat.eyebrow}
							</div>
							<div
								style={{
									fontFamily: fonts.headline,
									fontWeight: 800,
									fontSize: stat.value === '3 Secs' ? 74 : 80,
									color: stat.color,
									marginBottom: 18,
									transform: `translateY(${interpolate(numberProgress, [0, 1], [10, 0])}px)`,
									opacity: numberProgress,
									textAlign: 'center',
								}}
							>
								{stat.value}
							</div>
							<div
								style={{
									fontFamily: fonts.body,
									fontSize: 22,
									color: colors.muted,
									lineHeight: 1.42,
									maxWidth: 260,
									textAlign: 'center',
									textWrap: 'balance',
									minHeight: 124,
								}}
							>
								{stat.label}
							</div>
						</div>
					);
				})}
				</div>
			</div>
		</SceneContainer>
	);
};
